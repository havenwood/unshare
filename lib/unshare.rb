# frozen_string_literal: true

require "fiddle"
require "rbconfig"
require_relative "unshare/version"

# Give each thread its own working directory.
module Unshare
  raise NotImplementedError, "unshare requires CRuby" unless RUBY_ENGINE == "ruby"

  PLATFORM = case RbConfig::CONFIG["host_os"]
  when /darwin/ then :darwin
  when /linux/ then :linux
  else raise NotImplementedError, "unshare supports macOS and Linux only"
  end
  CLONE_FS = 0x00000200
  DIRECTORY_OPEN_MODE = case [PLATFORM, RbConfig::CONFIG["host_cpu"]]
  in [:darwin, _] then 0x40100000 # O_SEARCH
  in [:linux, /\Asparc/] then 1 << 24 # O_PATH
  in [:linux, /\Aalpha/] then 1 << 23
  in [:linux, /\A(?:hppa|parisc)/] then 1 << 22
  in [:linux, _] then 1 << 21
  end
  private_constant :CLONE_FS, :DIRECTORY_OPEN_MODE

  module Native
    module_function

    def function(name, args:, result: Fiddle::TYPE_INT)
      Fiddle::Function.new(Fiddle::Handle::DEFAULT[name], args, result, need_gvl: true)
    end

    LOCK_THREAD = function("rb_thread_lock_native_thread", args: [], result: Fiddle::TYPE_CHAR)
    if PLATFORM == :darwin
      CHDIR = function("pthread_chdir_np", args: [Fiddle::TYPE_VOIDP])
      FCHDIR = function("pthread_fchdir_np", args: [Fiddle::TYPE_INT])
      PTHREAD_SELF = function("pthread_self", args: [], result: Fiddle::TYPE_VOIDP)
      MACH_THREAD = function("pthread_mach_thread_np", args: [Fiddle::TYPE_VOIDP])
      THREAD_INFO = function("thread_info", args: [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP])
      PROC_INFO = function("proc_pidinfo", args: [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT])
      THREAD_IDENTIFIER_INFO = 4
      PROC_PIDTHREADPATHINFO = 10
    else
      UNSHARE = function("unshare", args: [Fiddle::TYPE_INT])
      CHDIR = function("chdir", args: [Fiddle::TYPE_VOIDP])
      FCHDIR = function("fchdir", args: [Fiddle::TYPE_INT])
    end

    def check(function, argument:, operation:, location: nil)
      raise SystemCallError.new(operation, Fiddle.last_error, location) unless function.call(argument).zero?
    end

    if PLATFORM == :darwin
      # Preserve overrides without pinning an inherited process directory.
      def thread_directory?
        thread = "\0" * 24 # thread_identifier_info
        count = [6].pack("L")
        port = MACH_THREAD.call(PTHREAD_SELF.call)
        status = THREAD_INFO.call(port, THREAD_IDENTIFIER_INFO, thread, count)
        raise "thread_info failed (#{status})" unless status.zero? && count.unpack1("L") >= 6

        handle = thread.byteslice(8, 8).unpack1("Q")
        info = "\0" * 1288 # proc_threadwithpathinfo
        size = PROC_INFO.call(Process.pid, PROC_PIDTHREADPATHINFO, handle, info, info.bytesize)
        raise SystemCallError.new("proc_pidinfo", Fiddle.last_error) if size <= 0
        raise "unexpected proc_pidinfo result: #{size} bytes" unless size == info.bytesize

        !info.byteslice(248, 4).unpack1("l").zero? # pvip.vip_vi.vi_type
      end
    end
  end
  private_constant :Native

  class << self
    def chdir(path = ENV["HOME"] || ENV["LOGDIR"] || raise(ArgumentError, "HOME/LOGDIR not set"), &block)
      path = File.path(path)
      path = path.encode(Encoding::UTF_8) if PLATFORM == :darwin && ![Encoding::UTF_8, Encoding::BINARY].include?(path.encoding)

      thread = Thread.current
      owner = thread.thread_variable_get(:__unshare_fiber__)
      raise ThreadError, "another fiber owns the thread directory" if owner && owner != Fiber.current

      Thread.handle_interrupt(Exception => :never) do
        Native::LOCK_THREAD.call unless owner
        unless block
          warn "conflicting chdir during another chdir block" if owner
          change_directory(path, owner:, scoped: false)
          return 0
        end
      end
      with_directory(path, thread:, owner:, &block)
    end

    private

    # Keep a handle in case the directory is renamed.
    def with_directory(path, thread:, owner:, &block)
      previous = nil
      changed = false
      begin
        Thread.handle_interrupt(Exception => :never) do
          previous = File.open(".", DIRECTORY_OPEN_MODE) if PLATFORM == :linux || owner || Native.thread_directory?
          change_directory(path, owner:, scoped: true)
          changed = true
          thread.thread_variable_set(:__unshare_fiber__, Fiber.current) unless owner
        end
        block.call(path)
      ensure
        Thread.handle_interrupt(Exception => :never) do
          restore_directory(previous) if changed
        ensure
          thread.thread_variable_set(:__unshare_fiber__, nil) unless owner
          previous&.close
        end
      end
    end

    def change_directory(path, owner:, scoped:)
      Native.check(Native::UNSHARE, argument: CLONE_FS, operation: "unshare(CLONE_FS)") if PLATFORM == :linux && !owner
      location = scoped ? "dir_chdir0" : "chdir_path"
      Native.check(Native::CHDIR, argument: path, operation: path, location:)
    end

    def restore_directory(previous)
      fd = previous&.fileno || -1
      Native.check(Native::FCHDIR, argument: fd, operation: "restore working directory")
    end
  end
end

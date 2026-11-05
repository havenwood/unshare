# frozen_string_literal: true

require "minitest/autorun"
require "minitest/pride"
require "minitest/hell"
require "tmpdir"
require "open3"
require "unshare"

Minitest::Test.prove_it!

class UnshareTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("unshare-test")
    @directory = File.realpath(@directory)
    File.write(File.join(@directory, "marker"), "thread local")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_changes_only_calling_thread_and_restores_it
    original = Dir.pwd
    entered = Queue.new
    proceed = Queue.new
    worker = Thread.new do
      result = Unshare.chdir(Pathname(@directory)) do
        entered << [Dir.pwd, File.read("marker")]
        proceed.pop
        :result
      end
      [result, Dir.pwd]
    ensure
      entered.close
    end
    assert_equal [@directory, "thread local"], (entered.pop || worker.value)
    assert_equal original, Dir.pwd
    proceed << true
    assert_equal [:result, original], worker.value
    assert_equal original, Dir.pwd
  ensure
    proceed << true if worker&.alive?
    worker&.join
  end

  def test_nested_scopes_restore_after_exception
    original = Dir.pwd
    Unshare.chdir(@directory) do
      assert_raises(RuntimeError) do
        Unshare.chdir("/") do
          assert_equal "/", Dir.pwd
          raise "failure"
        end
      end
      assert_equal @directory, Dir.pwd
    end
    assert_equal original, Dir.pwd
  end

  def test_nested_scope_restores_a_renamed_directory
    renamed = "#{@directory}-renamed"
    Unshare.chdir(@directory) do
      Unshare.chdir("/") { File.rename(@directory, renamed) }
      assert_equal renamed, Dir.pwd
    end
  ensure
    File.rename(renamed, @directory) if File.exist?(renamed)
  end

  def test_failed_change_and_block_validation
    original = Dir.pwd
    assert_raises(TypeError) { Unshare.chdir(nil) }
    assert_raises(ArgumentError) { Unshare.chdir("/", "/") }
    assert_raises(ArgumentError) { Unshare.chdir("bad\0path") { flunk } }
    missing = File.join(@directory, "missing")
    expected = assert_raises(Errno::ENOENT) { Dir.chdir(missing) { flunk } }
    actual = assert_raises(Errno::ENOENT) { Unshare.chdir(missing) { flunk } }
    assert_equal expected.message, actual.message
    expected = assert_raises(Errno::ENOENT) { Dir.chdir(missing) }
    actual = assert_raises(Errno::ENOENT) { Unshare.chdir(missing) }
    assert_equal expected.message, actual.message
    assert_equal original, Dir.pwd
  end

  def test_yields_path_and_returns_block_value
    path = Pathname(@directory)
    assert_equal [@directory, :result], Unshare.chdir(path) { |given| [given, :result] }
  end

  def test_path_encoding_matches_dir
    path = @directory.encode(Encoding::US_ASCII)
    expected = (Unshare::PLATFORM == :darwin) ? Encoding::UTF_8 : Encoding::US_ASCII
    assert_equal expected, Unshare.chdir(path) { |given| given.encoding }
  end

  def test_missing_home_and_logdir
    code = <<~'RUBY'
      [Dir, Unshare].each do |dir|
        begin
          dir.chdir
        rescue => error
          puts "#{error.class}:#{error.message}"
        end
      end
    RUBY
    output, status = Open3.capture2({"HOME" => nil, "LOGDIR" => nil}, RbConfig.ruby, "-Ilib", "-runshare", "-e", code)
    assert_predicate status, :success?
    assert_equal ["ArgumentError:HOME/LOGDIR not set"] * 2, output.lines.map(&:chomp)

    output, status = Open3.capture2({"HOME" => nil, "LOGDIR" => "/"}, RbConfig.ruby, "-Ilib", "-runshare", "-e", "puts Unshare.chdir { |path| path }")
    assert_predicate status, :success?
    assert_equal "/", output.chomp
  end

  def test_without_block_and_scoped_restoration
    original = Dir.pwd
    result = Thread.new do
      status = Unshare.chdir(@directory)
      inside = Unshare.chdir("/") { |path| [path, Dir.pwd] }
      [status, inside, Dir.pwd]
    end.value
    assert_equal [0, ["/", "/"], @directory], result
    assert_equal original, Dir.pwd
  end

  def test_default_path
    expected = ENV["HOME"] || ENV["LOGDIR"]
    assert_equal expected, Unshare.chdir { |path| path }
  end

  def test_overlapping_fibers_are_rejected
    Unshare.chdir(@directory) do
      fiber = Fiber.new { Unshare.chdir("/") { flunk } }
      assert_raises(ThreadError) { fiber.resume }
      assert_equal @directory, Dir.pwd
    end
  end

  def test_macos_preserves_external_overrides_and_process_inheritance
    skip "macOS only" unless Unshare::PLATFORM == :darwin

    code = <<~RUBY
      original = Dir.pwd
      if ARGV.first == "override"
        change = Fiddle::Function.new(Fiddle::Handle::DEFAULT["pthread_chdir_np"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        abort "pthread_chdir_np failed" unless change.call(original).zero?
      end
      begin
        Unshare.chdir("/tmp") do
          Dir.chdir("/")
          raise "test restoration"
        end
      rescue RuntimeError => error
        raise unless error.message == "test restoration"
      end
      puts original
      puts Dir.pwd
    RUBY

    %w[override inherited].each do |mode|
      output, status = Open3.capture2(RbConfig.ruby, "-Ilib", "-runshare", "-e", code, mode)
      assert_predicate status, :success?
      original, restored = output.lines.map(&:chomp)
      assert_equal((mode == "override") ? original : "/", restored)
    end
  end

  def test_respects_caller_interrupt_mask
    entered = Queue.new
    proceed = Queue.new
    events = Queue.new
    original = Dir.pwd
    worker = Thread.new do
      Thread.handle_interrupt(RuntimeError => :never) do
        Unshare.chdir(@directory) do
          entered << true
          proceed.pop
        end
        events << [:restored, Dir.pwd]
      end
    rescue RuntimeError
      events << :interrupted
    ensure
      entered.close
    end
    entered.pop || worker.value
    worker.raise(RuntimeError)
    proceed << true
    worker.join
    assert_equal [[:restored, original], :interrupted], Array.new(events.size) { events.pop }
  ensure
    proceed << true if worker&.alive?
    worker&.join
  end

  def test_restores_search_only_directory
    skip "root can read directories without permission" if Process.euid.zero?

    directory = File.join(@directory, "search-only")
    Dir.mkdir(directory)
    File.chmod(0o111, directory)
    Unshare.chdir(directory) do
      Unshare.chdir("/") { assert_equal "/", Dir.pwd }
      assert_equal directory, Dir.pwd
    end
  ensure
    File.chmod(0o700, directory) if directory && File.exist?(directory)
  end

  def test_restores_when_interrupted
    entered = Queue.new
    worker = Thread.new do
      Unshare.chdir(@directory) do
        entered << true
        sleep
      end
    rescue Interrupt
      Dir.pwd
    ensure
      entered.close
    end
    original = Dir.pwd
    entered.pop || worker.value
    worker.raise(Interrupt)
    assert_equal original, worker.value
  end
end

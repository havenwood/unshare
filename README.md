# Unshare

Thread-local `chdir` for CRuby on Linux and macOS, using Fiddle.

```ruby
require "unshare"

filename = "hello.txt"
dirname = "/tmp"
Unshare.chdir(dirname) do |path|
  File.write(filename, "Hello, world")
  puts "Wrote #{filename} to #{path}..."
end
#>> Wrote hello.txt to /tmp...
```

Like `Dir.chdir`.

On Linux, the thread’s root directory and umask stay unshared after the block ends.

Install with `gem install unshare`.

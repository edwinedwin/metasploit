module Rex
	Root = File.join(File.dirname(__FILE__), 'rex')
	LogSource = "rex"
end

# Generic classes
require 'rex/constants'
require 'rex/exceptions'
require 'rex/transformer'
require 'rex/text'
require 'rex/time'
require 'rex/job_container'
require 'rex/file'

# Thread safety and synchronization
require 'rex/sync/thread_safe'
require 'rex/sync/ref'
require 'rex/sync/read_write_lock'
require 'rex/sync/event'

# Encoding
require 'rex/encoder/xor'
require 'rex/encoding/xor'

# Architecture subsystem
require 'rex/arch'

# Assembly
require 'rex/assembly/nasm'

# Logging
require 'rex/logging/log_dispatcher'

# IO
require 'rex/io/stream'
require 'rex/io/stream_abstraction'
require 'rex/io/stream_server'

# Sockets
require 'rex/socket'

# Protocols

require 'rex/proto'

# Parsers
require 'rex/parser/arguments'
require 'rex/parser/ini'

# Overload the Kernel.sleep() function to be thread-safe
Kernel.class_eval("
	def sleep(seconds)
		Rex::ThreadSafe.sleep(seconds)
	end
")

# Overload the Kernel.select function to be thread-safe
Kernel.class_eval("
	def select(rfd = nil, wfd = nil, efd = nil, to = nil)
		Rex::ThreadSafe.select(rfd, wfd, efd, to)
	end
")


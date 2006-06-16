module Msf
module Ui
module Console
module CommandDispatcher

###
#
# Recon module command dispatcher.
#
###
class Auxiliary

	include Msf::Ui::Console::ModuleCommandDispatcher


	@@auxiliary_opts = Rex::Parser::Arguments.new(
		"-h" => [ false, "Help banner."                                                        ],
		"-j" => [ false,  "Run in the context of a job."                                       ],
		"-o" => [ true,  "A comma separated list of options in VAR=VAL format."                ],
		"-a" => [ true,  "The action to use.  If none is specified, ACTION is used."           ]
	)
		
	#
	# Returns the hash of commands specific to auxiliary modules.
	#
	def commands
		{
			"run" => "Initiates the auxiliary module",
		}.merge( (mod ? mod.auxiliary_commands : {}) )
	end

	#
	# Allow modules to define their own commands
	#
	def method_missing(meth, *args)
		if (mod and mod.respond_to?(meth.to_s)) 
			return mod.send(meth.to_s, *args)
		end
		return
	end

	#
	#
	# Returns the command dispatcher name.
	#
	def name
		"Auxiliary"
	end

	#
	# Executes the standard 'run' command
	#
	def cmd_run(*args)

		opt_str = nil
		action  = mod.datastore['ACTION']
		jobify  = false

		@@auxiliary_opts.parse(args) { |opt, idx, val|
			case opt
				when '-j'
					jobify = true
				when '-o'
					opt_str = val
				when '-a'
					action = val
				when '-h'
					print(
						"Usage: run [options]\n\n" +
						"Launches an auxiliary module.\n" +
						@@auxiliary_opts.usage)
					return false
			end
		}
	
		# Always run passive modules in the background
		if (mod.passive? or mod.passive_action?(action))
			jobify = true
		end
		
		begin
			mod.run_simple(
				'Action'         => action,
				'OptionStr'      => opt_str,
				'LocalInput'     => driver.input,
				'LocalOutput'    => driver.output,
				'RunAsJob'       => jobify
			)
		rescue ::Exception => e
			log_error("Auxiliary failed: #{e.to_s}")
			return false
		end
		
		if (jobify)
			print_status("Auxiliary module running as background job")		
		else
			print_status("Auxiliary module execution completed")
		end
	end

end

end end end end

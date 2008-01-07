module Msf
module Ui
module Gtk2
class MsfWindow

	#
	# This class performs a Gtk::Window to display a notebook of consoles from framework
	#
	class Consoles < Msf::Ui::Gtk2::SkeletonBasic

		class ConsoleOutput < Gtk::TextView

			attr_accessor :input, :prompt
			attr_accessor :pipe, :console
			attr_accessor :console_thread, :reader_thread

			class MyPipe < Rex::IO::BidirectionalPipe
				def prompting?
					false
				end
			end

			def initialize(*args)
				super(*args)

				buff = self.buffer
				buff.create_mark('end_mark', buff.end_iter, false)
				fixr = buff.create_tag("fixr", 
					{ 
						"font" => "Courier"
					}
				)
			end

			def append_output(data='')
				buff = self.buffer
				buff.insert(buff.end_iter, data, "fixr")
				buff.move_mark('end_mark', buff.end_iter)
				self.scroll_mark_onscreen(buff.get_mark('end_mark'))	
			end

			def start_console
				self.pipe = MyPipe.new
				self.pipe.create_subscriber('console')	

				self.console = Msf::Ui::Console::Driver.new(
					'msf',
					'>',
					{
						'Framework'   => $gtk2driver.framework,
						'LocalInput'  => self.pipe,
						'LocalOutput' => self.pipe
					}
				)

				self.console_thread = Thread.new { 

					begin

					self.console.run

					rescue ::Exception => e
		#				$stderr.puts "#{e.class} #{e} #{e.backtrace}"
					end			
				}

				self.reader_thread = Thread.new {
					begin

					while(true)
						data = self.pipe.read_subscriber("console")
						break if not data

						if(data.length > 0)
							append_output(data)
						else
							select(nil, nil, nil, 0.10)
						end
						
						self.prompt.text = self.pipe.prompt
						
						if (self.console.busy)
							self.prompt.text = " (busy) "
						end
						
						self.prompt.width_chars = self.prompt.text.length
					end

					rescue ::Exception => e
		#				$stderr.puts "#{e.class} #{e} #{e.backtrace}"
					end
				}
			end

			def stop_console
				self.reader_thread.kill if self.reader_thread
				self.console_thread.kill if self.console_thread
				self.console.stop if self.console
				self.pipe.close if self.pipe

				self.reader_thread = self.console_thread = self.pipe = self.console = nil
			end
		end


		class MyInput < Gtk::Entry

			attr_accessor :output, :history, :hindex

			def initialize(textview, *args)
				super(*args)
				self.output = textview

				self.history = []
				self.hindex  = 0
				
				self.signal_connect('activate') do |obj|
					
					line  = obj.text.strip
					parts = line.split(/\s+/)
					skip  = false
					
					case parts[0]
					when 'clear'
						skip = true
						self.output.buffer.text = ""
						self.history = []
						self.hindex  = 0
					end
				
					self.history.push(line)
					self.hindex = self.history.length - 1
					self.output.pipe.write_input(line+"\n") if not skip
					
					obj.text = ''
				end

				self.signal_connect('key-press-event') do |obj, key|
				
					case key.keyval
					when Gdk::Keyval::GDK_Up
						if history.length > 0
							self.text = history[hindex]
							self.hindex = self.hindex == 0 ? 0 : self.hindex - 1
							self.position = -1
						end
						true
					when Gdk::Keyval::GDK_Down
						if history.length > 0
							self.hindex = self.hindex >= (self.history.length-1) ? self.history.length-1 : self.hindex + 1
							self.text = history[hindex]
							self.position = -1
						end
						true
					when Gdk::Keyval::GDK_Tab
					
						res = self.output.console.tab_complete(self.text)

						if (res)

							case res.length
							when 0
							when 1
								self.text = res[0]
								self.position = -1
							else

								cmd_top = res[0]
								depth   = 0
								maxl    = 0

								while (depth < cmd_top.length)
									match = true
									res.each do |line|
										next if line[depth] == cmd_top[depth]
										match = false
										break
									end
									break if not match
									depth += 1
								end

								if (depth > 0)
									self.text = cmd_top[0, depth]
									self.position = -1
								end

								res.each do |line|
									maxl = line.length > maxl ? line.length : maxl
								end

								cols = 68/maxl
								cols = cols == 0 ? 1 : cols

								cols_def = []
								0.upto(cols-1) do |i|
									cols_def << ""
								end

								tbl = Rex::Ui::Text::Table.new(
									'Header'  => "",
									'Columns' => cols_def
								)

								0.step(res.length-1, cols) do |i|
									row = []
									0.upto(cols-1) do |z|
										row << res[i+z]
									end
									tbl << row
								end

								self.output.append_output(tbl.to_s)
							end
						end

						true
					else
						# Let the event filter up like normal
						false
					end
				end

				self.signal_connect('key-release-event') do |obj, key|
					next if key.keyval != Gdk::Keyval::GDK_Tab
					true
				end

			end

		end

		def create_console(tab, ident)

			label = Gtk::HBox.new(false, 1)
			label_txt = Gtk::Label.new( ident )
			label_btn = Gtk::Button.new
			label_btn.set_image(Gtk::Image.new(Gtk::Stock::CLOSE, Gtk::IconSize::MENU))
 			label_btn.relief = Gtk::RELIEF_NONE

			label.pack_start(label_txt, false, false, 5)
			label.pack_start(label_btn, false, false, 5)

			label.show_all

			vbox = Gtk::VBox.new
			scrl = Gtk::ScrolledWindow.new
			text = ConsoleOutput.new

			text.editable = false
			text.accepts_tab = false
			scrl.add(text)
			scrl.shadow_type = Gtk::SHADOW_NONE
			scrl.set_policy(Gtk::POLICY_AUTOMATIC, Gtk::POLICY_AUTOMATIC)

			vbox.pack_start(scrl, true, true, 0)

			hbox = Gtk::HBox.new
			prompt = Gtk::Entry.new
			prompt.set_size_request(-1, 25)
			prompt.text = "msf > "

			prompt.editable = false
			prompt.xalign = 1
			prompt.shadow_type = Gtk::SHADOW_NONE

			input = MyInput.new(text)
			input.set_size_request(-1, 25)
			input.shadow_type = Gtk::SHADOW_NONE
			input.focus = true

			text.prompt = prompt

			text.input  = input

			hbox.pack_start(prompt, false, false, 0)
			hbox.pack_start(input, true, true, 0)

			vbox.pack_start(hbox, false, true, 0)

			text.start_console

			tab.append_page(vbox, label)

			tab.set_page(tab.page_num(vbox))
			input.can_focus = true
			input.has_focus = true
			
			label_btn.signal_connect("clicked") do |obj|
				idx = tab.page_num(vbox)
				tab.remove_page(idx)
				text.stop_console
			end

		end
		
		include Msf::Ui::Gtk2::MyControls
		 
		def initialize

			super("Metasploit Console - #{Time.now.to_s}")
				
			set_window_position(Gtk::Window::POS_CENTER)
			set_default_size(640,480)
			set_border_width(1)
									
			app = self
			
			app.set_border_width(10)

			tab = Gtk::Notebook.new
			tab.set_tab_pos(Gtk::POS_TOP)
			tab.set_scrollable(true)

			vbox = Gtk::VBox.new
			hbox = Gtk::HBox.new

			btn = Gtk::Button.new("New Console")
			hbox.add(btn)

			vbox.pack_start(hbox, false, false, 0)
			vbox.pack_start(tab, true, true, 0)

			app.add(vbox)

			cnt = 0

			create_console(tab, "Console #{cnt+=1}")

			btn.signal_connect("clicked") do 
				create_console(tab, "Console #{cnt+=1}")
				tab.show_all
			end
			

			show_all
		end

	end

end
end
end
end

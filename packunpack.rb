# coding: utf-8

require 'optparse'
require 'pp'

Version = "1.1"

class SkylinesLocale
	def initialize(file, opt)
		@path = file
		# Struct::Data (実データ用)
		#   name:   String|Integer|nil （ポインタを指している場合は数値）
		#   index:  Integer|nil
		#   key:    String|Integer|nil （ポインタを指している場合は数値）
		#   value:  String|Integer|nil （数値型の場合は数値で格納）
		#   fvalue: String|true|nil （差分TSVが存在する時、その value のTSV上の表現（value == fvalue の時は true））
		#   ftrans: String|nil （差分TSVが存在する時、その translation のTSV上の表現）
		@format = Struct.new("Data", :name, :index, :key, :value, :fvalue, :ftrans)
		# Struct::Header (特殊行用)
		#   name:   String|nil
		#   value:  String|Integer|nil （数値型の場合は数値で格納）
		#   key:    String|nil
		#   fvalue: String|true|nil （差分TSVが存在する時、その value のTSV上の表現（value == fvalue の時は true））
		#   ftrans: String|nil （差分TSVが存在する時、その translation のTSV上の表現）
		#   ※ value, key の順なのは互換性のため
		@hformat = Struct.new("Header", :index, :value, :key, :fvalue, :ftrans)
		# Struct::Counter (カウンタ行用)
		#   name:   String|Integer|nil （ポインタを指している場合は数値）
		#   key:    String|Integer|nil （ポインタを指している場合は数値）
		#   value:  Integer|nil
		#   fvalue: String|true|nil （差分TSVが存在する時、その value のTSV上の表現（value == fvalue の時は true））
		#   ftrans: String|nil （差分TSVが存在する時、その translation のTSV上の表現）
		@cformat = Struct.new("Counter", :name, :key, :value, :fvalue, :ftrans)
		@sig = "0000"
		@table = []
		@list = []
		@minimum = opt[:min]
		@exclude = opt[:exc]
		@no_format = opt[:unf]
		@ostracize = opt[:ost]
		@diagnosis = opt[:dia]
		@diff = opt[:dff]
		@timestamp = Time.now.strftime("%F-%T").tr(":", "-")

		peek = File.open(@path, "rb")
		top = peek.read(6)
		peek.close

		if top.unpack('H4')[0].upcase == @sig
			decode
			read(@diff) if @diff
			output
		else
			read
			encode
		end
	end

	# .locale -> 内部形式
	def decode
		input = File.open(@path, "rb")
		h0 = input.read(6).unpack('H12')[0]
		hv = h0[0..7].hex

		if hv > 3
			print "未対応の.localeバージョン(#{hv})です。正しく読み込めない可能性があります。続行しますか？ はい→Y / いいえ→N … "
			
			while true
				answer = gets
				case answer
				when /^[Yy]/
					break
				when /^[Nn]/
					abort "読み込みを中止しました"
				else
					print "Y (続行)か N (終了)キーを押して改行してください… "
				end
			end
		end

		def eof_error; raise "データが途中で終わっています。.localeファイルが破損している可能性があります。"; end

		hindex = 0
		@list << @hformat.new(hindex, "<<#{h0.upcase}>>", "version-etc")
		h1, p1 = string_unmask(input.pos)
		@list << @hformat.new(hindex += 1, h1, "class")
		h2, p2 = string_unmask(p1)
		@list << @hformat.new(hindex += 1, h2, "native-name")
		h3, p3 = string_unmask(p2)
		@list << @hformat.new(hindex += 1, h3, "english-name")
		if hv >= 2
			input.pos= p3
			h4 = input.read(4).unpack('H8')[0]
			@list << @hformat.new(hindex += 1, "<<#{h4.upcase}>>", "app-id")
			pe = input.pos
		else
			pe = p3
		end
		input.pos= pe

		["index", "data"].each { |name|
			foray = input.read(4)
			eof_error unless foray
			count = foray.unpack('N')[0]
			format = name == "index" ? @cformat : @format
			@list << @hformat.new(hindex += 1, count, "#{name}-count")

			count.times do
				entry = format.new

				first = input.read(1)
				case first.ord
				when 0xFE
					entry.name, pos = string_unmask(input.pos)
					@table << entry.name
					input.pos= pos
				when nil; eof_error
				else
					entry.name = first.concat(input.read(1)).unpack('n')[0]
				end

				index_num = input.read(4).unpack('N')[0]
				eof_error unless index_num
				entry.index = index_num if name == "data"

				second = input.read(1)
				case second.ord
				when 0xFE
					entry.key, pos = string_unmask(input.pos)
					@table << entry.key
					input.pos= pos
				when 0xFF
					entry.key = nil
				when nil; eof_error
				else
					entry.key = second.concat(input.read(1)).unpack('n')[0]
				end

				third = input.read(3).unpack("C*")
				eof_error unless third
				if third.inject(:+) == 0
					entry.value = input.read(1).ord
				elsif third[0] == 0 || third[0] == 0x80
					entry.value, pos = string_unmask(input.pos-3)
					input.pos= pos
				else;p @list
					raise "不明な形式に遭遇しました。 pos: #{input.pos} / #{entry.inspect}"
				end

				@list << entry
			end
		}
		
		if hv >= 3
			# version 3 形式対応
			endoffile = input.read(1)
			if endoffile.ord != 0x01
				raise "終端文字が不正です pos: #{input.pos}, char: #{endoffile.ord}"
			end
			input.pos = input.pos + 1
		end

		raise "pos: #{input.pos} で処理が終了しました。.localeファイルが破損している可能性があります。" if input.size > input.pos

		input.close
	end

	# 内部形式 -> .locale
	def encode
		open("output-#{@timestamp}.locale", "wb") { |loc|

			@list.each { |e|
				if e.is_a?(Struct::Header)
					if e.value =~ /^<<([0-9A-F]+)>>$/
						val = [$1].pack("H*")
					elsif e.value.is_a?(Integer)
						val = [e.value].pack("N")
					else
						val = string_mask(e.value)
					end
					loc.write val
				else
					name = e.name.is_a?(Integer) ? [e.name].pack("n") : 0xFE.chr << string_mask(e.name)
					index = e.is_a?(Struct::Counter) ? [0].pack("N") : [e.index].pack("N")
					if e.key == nil
						key = 0xFF.chr
					elsif e.key.is_a?(Integer)
						key = [e.key].pack("n")
					else
						key = 0xFE.chr << string_mask(e.key)
					end
					value = e.value.is_a?(Integer) ? [e.value].pack("N") : string_mask(e.value)
					loc.write name << index << key << value
				end
			}
		  # version 3 形式対応
		  loc.write 0x01.chr
		}
	end

	# .tsv -> 内部形式
	def read(diff = false)
		path = diff ? diff : @path
		if diff
			deleted = []
			r = -> a { a.is_a?(Integer) ? @table[a] : a.to_s }
			ilist = @list.map.with_index { |e, i| [i, e] }
			list_h = ilist.select { |e| e[1].is_a?(Struct::Header) }
			list_c = ilist.select { |e| e[1].is_a?(Struct::Counter) }.map { |e| [e[0], [r[e[1].name], r[e[1].key]]] }
			list_d = ilist.select { |e| e[1].is_a?(Struct::Data) }.map { |e| [e[0], [r[e[1].name], r[e[1].key], e[1].index]] }
		end
		gyoto = /[?!？！ゝゞーァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎゕゖ々,\)\]）｝、〕〉》」』】〙〗〟’”｠»。.\u3099-\u309C\uFF9E\uFF9F\r\n]/
		gyomatsu = /[\(\[（｛〔〈《「『【〘〖〝‘“｟«]/
		waji = /[\p{Han}\p{Hira}\p{Kana}]/
		replacer = /\\[trns]/, {'\t' => "\t", '\r' => "\r", '\n' => "\n", '\s' => "\u200B"}
		stage = 0
		version = 1

		open(path, "r:utf-8") { |csv|
			csv.each.with_index(1) { |line, lidx|
				next if line =~ /^name/
				cols = line.chomp.split("\t")
				if cols.size < 6
					puts "TSV #{lidx} 行目に不正な行があります（余分な改行を含む可能性）"
					pp cols
					abort
				end
				name, key, ref_name, ref_key, index, value, translation, former_value, former_translation = cols

				true_name = (name == ref_name) ? name : name.to_i
				index = index.to_i
				true_key = (key == ref_key) ? key : key.to_i
				true_key = nil if true_key == ''
				true_string = translation.to_s.empty? ? value : translation
				true_string = true_string.empty? ? nil : true_string.gsub(*replacer)

				if true_string =~ /^\[\[0x([0-9A-F]+)\]\]$/
					formatted = $1.hex
					is_num = true
				elsif @no_format
					formatted = true_string
				else
					leng = true_string.size if @minimum
					formatted = if
						@minimum ? leng >= @minimum : true and
						@exclude ? !@exclude.include?(lidx) : true and
						!checkup(ref_name, ref_key, index)
					then true_string.chars.each_with_index {|e, i|
							f = true_string[i+1] || next
							e << "\u200B" if e =~ waji || f =~ waji and e !~ gyomatsu and f !~ gyoto
						}.join('')
					else
						puts [lidx, ref_name, ref_key, index, true_string].join("\t") if @diagnosis
						true_string
					end
				end

				is_header = true_name == '###HEADER'
				version = value[2..9].hex if is_header && (true_key == "version-etc" || index == 0)
				stage += 1 if is_header && (true_key =~ /^(index|data)-count/ || (version > 1 ? 5..6 : 4..5) === index)
				if diff
					v, w = is_num ? [formatted, value] : [value.gsub(*replacer), value]

					x = 
					if is_header
						list_h.find { |e| (e[1].key == ref_key || e[1].index == index) }
					elsif stage > 1
						list_d.find { |e| e[1] == [ref_name, ref_key, index] }
					else
						list_c.find { |e| e[1] == [ref_name, ref_key] }
					end

					if x
						found = @list[x[0]]
						if is_header
							raise "#{diff}: #{lidx} 行目に不正なデータ（index: #{index} が重複）" if found[:fvalue]
						else
							raise "#{diff}: #{lidx} 行目に不正なデータ（#{ref_name}{#{ref_key}}[#{index}] が重複）" if found[:fvalue] && found.fvalue.class == formatted.class
						end
						found.fvalue = found.value == v ? true : w
						found.ftrans = translation.to_s.empty? ? '' : translation
					else
						deleted << {line: lidx, name: ref_name, key: ref_key, index: index, value: value}
					end
				else
					if is_header
						@list << @hformat.new(index, formatted, true_key)
					elsif stage > 1
						@list << @format.new(true_name, index, true_key, formatted)
					else
						@list << @cformat.new(true_name, true_key, formatted)
					end
				end
			}
		}

		if diff
			open("deleted-#{@timestamp}.txt", "w") { |io|
				io.puts "#{diff} → #{@path} で消滅した行:"
				deleted.each do |del|
					io.puts [del[:line], del[:name], del[:key], del[:index], del[:value]].join("\t")
				end
			}
		end
	end

	# 内部形式 -> .tsv
	def output
		colnames = ["name", "key", "ref_name", "ref_key", "index", "value", "translation"]
		colnames << "former_value" << "former_translation" if @diff
		nf = -> n { "[[0x#{n.to_s(16).upcase}]]" }
		open("#{File.basename(@path)}-#{@timestamp}.tsv", "w:utf-8") { |out|
			
			out.puts colnames.join("\t")

			@list.each do |e|
				name = e.is_a?(Struct::Header) ? '###HEADER' : e.name
				key = e.key
				value = e.value.is_a?(Integer) ? nf[e.value] : e.value
				ref_name = name.is_a?(Integer) ? @table[name] : name
				ref_key = key.is_a?(Integer) ? @table[key] : key
				index = e.is_a?(Struct::Counter) ? 0 : e.index
				translation =
				if !@diff || e.value.is_a?(Integer) then ''
				else
					case e[:fvalue]
					when nil then "+++"
					when true then e[:ftrans]
					else "***"
					end
				end
				former_value = 
				case e[:fvalue]
				when String then e[:fvalue]
				when Integer then nf[e[:fvalue]]
				else ''
				end
				former_translation = e[:fvalue].is_a?(TrueClass) ? '' : e[:ftrans]

				value.to_s.gsub!(/[\t\r\n\u200B]/, {"\t" => '\t', "\r" => '\r', "\n" => '\n', "\u200B" => '\s'})

				out.puts [name, key, ref_name, ref_key, index, value, translation, former_value, former_translation].join("\t")
			end
		}
	end

	# UTF-8 -> .locale 文字形式
	def string_mask(string)
		if /[^\u0000-\u00ff]/ =~ string
			seq = string.encode("UTF-16BE").unpack("n*")
			masked = []
			seq.each_with_index do |e, i|
				prev = (i > 0) ? seq[i-1] : 0x80
				masked[i] = (e - prev) % 0x10000
			end
			return 0.chr << [string.size].pack("n") << masked.pack("n*")
		else
			seq = string.encode("ISO-8859-1").codepoints
			masked = []
			seq.each_with_index do |e, i|
				prev = (i > 0) ? seq[i-1] : 0x80
				masked[i] = (e - prev) % 0x100
			end
			return 0x80.chr << [string.size].pack("n") << masked.pack("C*")
		end
	end

	# .locale 文字形式 -> UTF-8
	def string_unmask(pos)
		file = File.open(@path, "rb")
		file.pos= pos
		flag = file.read(1).ord
		case flag
		when 0x80
			enc, format, unit = 'ISO-8859-1', 'C*', 1
		when 0
			enc, format, unit = 'UTF-16BE', 'n*', 2
		else
			raise "位置 #{pos} は文字列ではありません。"
		end

		length = file.read(2).unpack('n')[0]
		box = []
		mod = ("FF"*unit).hex + 1
		length.times do
			byte = file.read(unit).unpack('H*')[0].hex
			prev = box.empty? ? 0x80 : box[-1]
			result = (prev + byte) % mod
			box << result
		end

		lastpos = file.pos
		file.close
		return [box.pack(format).encode('UTF-8', enc), lastpos]
	end

	# 除外行判定
	def checkup(name, key, index)
		pairs = {name: name, key: key, index: index}.to_a
		@ostracize && @ostracize.each do |o|
			return true if pairs.inject(true) { |s, p| s & (!o[p[0]] || o[p[0]].include?(p[1])) }
		end
		return false
	end
end

h_head, h_unf, h_min, h_exc, h_diag = [<<HHEAD, <<HUNF, <<HMIN, <<HEXC, <<HDIAG].map { |e| e.each_line.map(&:chomp) }
C:SL 日本語化スクリプト v1.1

ruby packunpack.rb [.localeファイルのパス] ([古い.tsvファイルのパス])
 => 現在のフォルダに **.locale-(時刻).tsv を出力
 ※古い.tsvを指定した場合、マージモード(変更のない翻訳を流用)
 　.tsv と deleted-(時刻).txt を出力します(削除行がある場合)
ruby packunpack.rb ([オプション]) [.tsvファイル(UTF-8)のパス]
 => 現在のフォルダに output-(時刻).locale を出力
HHEAD
改行処理を行いません
（他のオプションは無視される）
HUNF
改行処理を行う最小の文字数
（6なら5文字以下は飛ばす）
HMIN
改行処理を飛ばす条件
EXPR の例:
 "1" => .tsv の 1 行目
 "2-5" => 同 2 から 5 行目
 "A/B{C/D}[E-F/G]" (名前指定)
 => .tsv の…
  ref_name 列が A または B、かつ
  ref_key 列が C または D、かつ
  index 列が E 以上 F 以下か G
  …にあてはまる行を除外
  ※keyの中のスペースは"+"に直して下さい
    Fire Truck -> {Fire+Truck}
  name, key, index部はそれぞれ省略可
  省略した部分は絞り込まないのと同じです
（※ -D で除外された行を確認）
HEXC
診断出力モード
m、xで除外された行を表示します
オプション指定が正しかったかの確認用
（処理すべき文字がなかっただけの行は出ません）
HDIAG

args = OptionParser.new
opts = {}
args.banner = "説明:"
args.on_head(*h_head)
args.separator('')
args.on('-U', '--unformatted', *h_unf) { |v| opts[:unf] = true }
args.on('-m INT', '--min=INT', Integer, *h_min) { |v| opts[:min] = v }
args.on('-x EXPR[,EXPR,...]', '--exclude=EXPR[,EXPR,...]', Array, *h_exc) { |v|
	unify = lambda { |unit| /\A(\d+)-(\d+)\Z/ =~ unit ? ($1.to_i .. $2.to_i).to_a : [unit.to_i] }
	v.each { |n|
		case n
		when %r|\A([A-Z][A-Z0-9_/]*)?(?:\{([-A-Za-z0-9_+/]+)\})?(?:\[([-\d/]+)\])?\Z|
			opts[:ost] ||= []
			names, keys, indices = [$1, $2, $3].map { |e| e && !e.empty? ? e.split("/") : nil }
			keys.map! { |k| k.gsub("+", " ") } if keys
			indexes = indices ? indices.map(&unify).flatten.uniq : nil
			opts[:ost] << {name: names, key: keys, index: indexes}
		else
			opts[:exc] ||= []
			opts[:exc] |= unify.call(n)
		end
	}
}
args.on('-D', '--diag', *h_diag) { |v| opts[:dia] = true }

args.parse!(ARGV)
target = ARGV.shift
oldtsv = ARGV.shift
opts[:dff] = oldtsv if oldtsv

if target
	SkylinesLocale.new(target, opts)
else
	puts "「ruby packunpack.rb --help」で説明が出ます"
end
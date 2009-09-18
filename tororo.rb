# coding: UTF-8
# tororo pre alpha
$KCODE = 'utf8'

require 'find'
require 'suikyo/suikyo'

class Tororo
  def initialize
    # ここらへんはconfigファイルを読んで各種ファイル名を取得したい
    DEFAULT_TYPE = "romaji"
    YOUR_TYPE = "romaji"
    @to_hira = Hash.new
    Find.find("./conv-table") {|path|
      if File.file?(path) then
        filename = File.basename(path)
        @to_hira[filename] = Suikyo.new
        @to_hira[filename].table.loadfile(filename)
      end
    }
    @foreign = Suikyo.new
    @foreign.table.loadfile("foreign","./dic")
    @nippon = Suikyo.new
    @nippon.table.loadfile("nippon","./dic")
    @denial = SimpleTable.new
    @denial.loadfile("!denial!", "./dic") # 変換拒否単語リスト
    @players = SimpleTable.new("./rule/players") # 更新用の出力ファイルの指定が必要
    @players.loadfile("players", "./rule")
    @white = AllowList.new
    @white.loadfile("whitelist", "./rule")

    #@log_path_input = log_path_input
    #@log_path_output = "./log/" + File::basename(log_path_input)
    @log_path_in = ""
    #@log_path_out = "./log/" + File::basename(log_path_input)
    @log_lines = []
    @log_line_num = 0 # すでに変換した行数
    @log_mtime = 0
  end
  
  def conv_from_log(filepath)
    @log_path_in = filepath
    @log_line_num = 0
    read_log_all
    str = ""
    @log_lines.each {|line|
      str += conv(line) + "\r\n"
      @log_line_num += 1
    }
    return str
  end

  def conv_continue
    str = "";
    return str  unless log_changed?
    read_log_all
    return str if @log_line_num > @log_lines.length
    @log_lines[@log_line_num..-1].each {|line|
      str += conv(line) + "\r\n"
      @log_line_num += 1
    }
    return str
  end

  def conv(str)
    # ASCII-8bit 以外の文字があったらそのまま返す
    # ここは Ruby 1.9 だとエラーになる /[^\u0000-\x00FF]/ だといい？
    return str if /[^\x00-\xFF]/ =~ str
    # ホワイトリストに載っていれば変換
    if pos = @white.apply_filter(str) then
      # プレイヤー名から入力方式を取得
      if player_name = @white.get_playername(str) then
        if @players.exist?(player_name) then
          type = @players.get_param(player_name)
        else
          type = DEFAULT_TYPE
          @players.set(player_name, type, true)
        end
      # プレイヤー名が見つからなかったら自分の発言と判断する
      else
        type = YOUR_TYPE
      end
      return str unless @to_hira.include?(type) # 入力方式が存在しない場合はそのまま返す
      # 無変換部分と変換部分に分ける
      no_convstr = str[0...pos]
      convstr    = str[pos...str.length]
      str = no_convstr
      convstr = conv_foreign(convstr)
      i = 0
      setoff(convstr).each {|words| # [括弧外,括弧内,括弧外,括弧内,...]
        if i % 2  == 0 then # 偶数は[]括弧外で変換対象 奇数は[]括弧内で無変換
          divide_by_blank(words).each {|word| # 変換対象を変換
            word += " "
            unless @denial.exist?(word.chop) then # 変換拒否単語か？
              if @to_hira[type].valid?(word) then
                str += @nippon.convert(@to_hira[type].convert(word))
              else
                str += word
              end
            else
              str += word
            end
          }
        else
          str += words + " "
        end
        i += 1
      }
      # strip でスペースを抜こうとすると文末の「だ」が1バイト削られちゃう
      #return str.strip
      str.chop!
    end
    return str
  end

  def conv_foreign(str)
    return @foreign.convert(str)
  end

  # 括弧外文字列と括弧内文字列で分割した配列を返す
  # 戻り値の偶数配列は括弧外，奇数は括弧内
  def setoff(str)
    str_array = []
    split_array = []
    str_array.push str
    i = 0
    # "[" が現れなくなるまで続ける
    while (split_array = str_array[i].split("[", 2)).size > 1
      # str_array に，分割した文字列配列を溜めこむ
      str_array.pop # 邪魔な分割前の文字列を排除
      str_array += split_array
      str_array[i+1] = "[" + str_array[i+1] # 括弧内文字列の先端に "[" を足す
      # "]" が存在しない場合は，終端までを括弧内としてループから出る
      unless (split_array = str_array[i+1].split("]", 2)).size > 1 then
        break
      end
      # 上の作業と同様
      str_array.pop
      str_array += split_array
      str_array[i+1] += "]"
      i += 2 # 2分割ずつ処理するので2つ進める
    end
    return str_array
  end

  def divide_by_blank(str)
    array = str.split(" ")
    return array
  end

  def read_log_all
    open(@log_path_in, "r") do |f|
      @log_lines = f.readlines
      @log_mtime = f.mtime
    end
  end
  
  def log_changed?
    open(@log_path_in, "r") do |f|
      return (f.mtime > @log_mtime)
    end
  end


end

class SimpleTable
  def initialize(output_file = "")
    @word = Hash.new
    @list_files = []
    @output_file = output_file
  end

  def loadfile (filename, tablepath = nil)
    filepath = File::join2(tablepath, filename)
    if FileTest::exist?(filepath) then
      @list_files.push(filepath)
    else
      $stderr.puts "tororo.rb: '#{filepath}' is not found."
      return false
    end
    open(filepath, "r").readlines.each {|line|
      line.chomp!
      unless line =~ /^\#|^\s*$/ then
        (key, param) = line.sub(/^ /, "").split(/\t/,2)
         # キーのみ（タブ文字以降のデータなし）の場合は存在だけを知らせる
        param = true unless param
        @word[key] = param
      end
    }
    
    return true
  end

  def update_file(key)
    open(@output_file, "a") {|f|
      # f.flock(File::LOCK_EX | File::LOCK_NB)
      f.write(key + "\t" + @word[key] + "\n")
    }
  end

  def set(key, param, update = false)
    @word[key] = param
    if update then
      update_file(key)
    end
  end
  
  def exist?(key)
    return @word.include?(key)
  end

  def get_param(key)
    return @word[key]
  end

end

# 変換許可
class AllowList
  attr_reader :list_files
  
  def initialize
    @word = []
    @list_files = []
    @mached_regexp = nil
  end
  
  # 今のところは正規表現だけサポート
  def set(str)
    if /^\/(.*)\/$/ =~ str then
      @word.push(Regexp.new($1))
    end
  end

  def unset(str)
    if  /^\/(.*)\/$/ =~ str then
      @word.delete(Regexp.new($1))
    end
  end
  
  def loadfile (filename, tablepath = nil)
    filepath = File::join2(tablepath, filename)
    if FileTest::exist?(filepath) then
      @list_files.push(filepath)
    else
      $stderr.puts "tororo.rb: whitelist '#{filepath}' is not found."
      return false
    end
    open(filepath, "r").readlines.each{|line|
      line.chomp!
      unless line =~ /^\#|^\s*$/ then
        set(line)
      end
    }
    return true
  end

  
  def apply_filter(str)
    @mached_regexp = nil
    allword.each {|regexp|
      if regexp =~ str then
        @mached_regexp = regexp
        return $~.end(0)
      end
    }
    return nil
  end

# 変換対象文字列の開始位置を取得
# とりあえずマッチした文字列の終端を開始位置とする
  def get_startposition(str)
    if @mached_regexp =~ str then
      return $~.end(0)
    end
    return nil
  end

  def get_playername(str)
    if @mached_regexp =~ str then
      return $1
    end
    return nil
  end

  def allword
    return @word
  end
  
end

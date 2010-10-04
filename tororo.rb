# coding: UTF-8
$KCODE = 'utf8'

require 'find'
require 'yaml'
require 'suikyo/suikyo'

class Tororo
  attr_reader :version
  def initialize
    @version = "0.2.0"
    @log_path_in = ""
    @log_lines = []
    @count = 0 # すでに変換した行数
    @log_mtime = 0
    load_config
  end

  def load_config
    config = YAML.load_file("config.yaml")
    
    @default_input_table = config["default_input_table"]
    @your_input_table    = config["your_input_table"]
    @input_tables = Hash.new
    Find.find(config["input_tables_dir"]) {|pathname|
      if File.file?(pathname) then
        filename = File.basename(pathname)
        @input_tables[filename] = TororoSuikyo.new
        @input_tables[filename].table.loadfile(filename)
      end
    }
    @charas       = build_table(CharacterID,  config["character_id_tables"])
    @line_allower = build_table(LineAllower,  config["line_whitelist_tables"])
    @foreign_lang = build_table(TororoSuikyoMore, config["foreign_lang_dics"])
    @nippon       = build_table(TororoSuikyo, config["hiragana_to_kanjikana_dics"])
    @word_denier  = build_table(WordDenier,  config["word_blacklist_tables"])
    @charas.output_file = config["character_id_table_output"]
    @quote_foreign_lang = config["quote_foreign_lang"] ? true : false
    @foreign_lang.punctuation_marks = config["punctuation_marks"]
  end

  # 複数のテーブルファイルを一つのテーブルデータに集める
  def build_table(target_class, file_list)
    target = target_class.new
    file_list.each {|pathname|
      dirname, filename = File.split(pathname)
      target.table.loadfile(filename, dirname)
    }
    return target
  end

  def read_log_all
    open(@log_path_in, "r") {|f|
      @log_lines = f.readlines
      @log_mtime = f.mtime
    }
  end
  
  def log_changed?
    open(@log_path_in, "r") {|f|
      return (f.mtime > @log_mtime)
    }
  end
  
  def conv_from_log(filepath)
    @log_path_in = filepath
    @count = 0
    read_log_all
    str = ""
    @log_lines.each {|line|
      line.chomp!
      str += conv(line) + "\r\n"
      @count += 1
    }
    return str
  end

  def conv_continue
    str = "";
    return str  unless log_changed?
    read_log_all
    return str if @count > @log_lines.length
    @log_lines[@count..-1].each {|line|
      line.chomp!
      str += conv(line) + "\r\n"
      @count += 1
    }
    return str
  end

  def conv_to_file(str, filename)
    str = conv(str)
    open(filename, "w") {|f|
      f.write(str)
    }
  end

  def conv(str)
    # ASCII-8bit 以外の文字があったらそのまま返す
    # ここは Ruby 1.9 だとエラーになる /[^\u0000-\u00FF]/ だといい？
    return str if /[^\x00-\xFF]/ =~ str
    # フィルターで許可されていれば変換
    if @line_allower.apply_filter(str) then
      # フィルター結果からキャラクター名を取得
      if chara_name = @line_allower.get_character_name then
        # キャラクター名から入力方式を取得
        # キャラクター ID テーブルに存在しなかったら規定値の入力方式にする
        unless type = @charas.get_input_type(chara_name) then
          type = @default_input_table
          @charas.table.set(chara_name, type)
          @charas.update_file(chara_name, type)
        end
      # フィルター結果からキャラクター名を取得できなければ自分の発言と判断
      else
        type = @your_input_table
      end
      return str unless @input_tables.include?(type) # 入力方式が存在しない場合はそのまま返す
      # 無変換部分と変換部分に分ける
      pos = @line_allower.get_convert_start_position
      no_convstr = str[0...pos]
      convstr    = str[pos...str.length]
      str = no_convstr
      convstr = @foreign_lang.convert( \
        convstr, @foreign_lang.table, true, @quote_foreign_lang)
      i = 0
      setoff(convstr).each {|words| # [括弧外,括弧内,括弧外,括弧内,...]
        # 偶数は[]括弧外で変換対象 奇数は[]括弧内で無変換
        if i % 2  == 0 then
          # スペースで区切って変換させる
          divide_by_blank(words).each {|word|
            word += " "
            unless @word_denier.deny?(word.chop) then # 変換拒否単語か？
              if @input_tables[type].valid?(word) then
                str += @nippon.convert(@input_tables[type].convert(word))
              else
                str += word
              end
            else
              str += word
            end
          }
        # 無変換部分（[]内）
        else
          str += words + " "
        end
        i += 1
      }
      # strip でスペースを抜こうとすると文末の「だ」が1バイト削られちゃう
      # return str.strip
      str.chop!
    end
    return str
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
    array = str.split(/ /)
    return array
  end
end

# キャラクタ同定
# 今は入力方式のみ
class CharacterID
  attr_reader :table
  attr_writer :output_file
  def initialize
    @table = SimpleTable.new
    @output_file = ""
  end
  
  def update_file(chara_name, input_type)
    @table.set(chara_name, input_type)
    open(@output_file, "a") {|f|
      f.write(chara_name + "\t" + input_type + "\n")
    }
  end

  def get_input_type(chara_name)
    return @table.get_value(chara_name)
  end
end

# 変換しない単語
class WordDenier
  attr_reader :table
  def initialize
    @table = IgnoreCasingTable.new("cs")
  end

  def deny?(word)
    return @table.exist?(word)
  end
end

# 1つの値を持つハッシュのテーブル
class SimpleTable
  def initialize
    @word = Hash.new
    @list_files = []
  end

  def loadfile (filename, tablepath = nil)
    filepath = File::join2(tablepath, filename)
    if FileTest::exist?(filepath) then
      @list_files.push(filepath)
    else
      $stderr.puts "tororo.rb: SimpleTable '#{filepath}' is not found."
      return false
    end
    open(filepath, "r").readlines.each {|line|
      line.chomp!
      unless line =~ /^\#|^\s*$/ then
        key, value = line.sub(/^ /, "").split(/\t/)
         # キーのみ（タブ文字以降のデータなし）の場合は存在だけを知らせる
        value = true unless value
        set(key, value)
      end
    }
    return true
  end

  def set(key, value)
    @word[key] = value
  end

  def unset(key)
    @word.delete(key)
  end
  
  def exist?(key)
    return @word.include?(key)
  end

  def get_value(key)
    return @word[key]
  end
end

# 大文字小文字を区別しないテーブル
# 引数が case_sensitive_value の場合は区別
class IgnoreCasingTable < SimpleTable
  def initialize(case_sensitive_value = nil)
    @word = Hash.new
    @case_sensitive_value = case_sensitive_value
    @list_files = []
  end

  def loadfile (filename, tablepath = nil)
    filepath = File::join2(tablepath, filename)
    if FileTest::exist?(filepath) then
      @list_files.push(filepath)
    else
      $stderr.puts "tororo.rb: IgnoreCasingTable '#{filepath}' is not found."
      return false
    end
    open(filepath, "r").readlines.each {|line|
      line.chomp!
      unless line =~ /^\#|^\s*$/ then
        key, value = line.sub(/^ /, "").split(/\t/)
        # キーのみ（タブ文字以降のデータなし）の場合は存在だけを知らせる
        value = true unless value
        # 大文字小文字の区別なしの単語は小文字のキーにする
        key.downcase! unless @case_sensitive_value == value
        set(key, value)
      end
    }
    return true
  end

  def exist?(key)
    # 大文字小文字の区別なしのキーは小文字に変換してあるので，
    # 区別の判定が必要になるのは最初の if で弾かれたときだけ
    if @word.include?(key) then
      return true
    elsif @word.include?(key.downcase) and \
          @word[key.downcase] != @case_sensitive_value then
      return true
    else
      return false
    end
  end
end

# 行ごとの変換許可（正規表現）
class LineAllower
  attr_reader :table
  def initialize
    @table = FilterTable.new
    @match_data = MatchData
  end

  def apply_filter(str)
    @match_data = @table.try_match(str)
  end

  # 1番目にマッチした部分文字列はキャラクタ名
  def get_character_name
    return nil unless @match_data
    return @match_data[1]
  end
  # 変換対象文字列の開始位置を取得
  # とりあえずマッチした文字列の終端を開始位置とする
  def get_convert_start_position
    return nil unless @match_data
    return @match_data.end(0)
  end
end

# 正規表現のフィルターテーブル
class FilterTable
  attr_reader :table_files
  def initialize
    @word = []
    @table_files = []
  end
  
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
      @table_files.push(filepath)
    else
      $stderr.puts "tororo.rb: FilterTable '#{filepath}' is not found."
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
  
  def try_match(str)
    allword.each {|regexp|
      if regexp =~ str then
        return Regexp.last_match
      end
    }
    return nil
  end

  def allword
    return @word
  end
end

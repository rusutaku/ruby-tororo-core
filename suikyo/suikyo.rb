# coding: UTF-8
# suikyo.rb: Romaji-Hiragana conversion library for Ruby
# $Id: suikyo.rb,v 1.19 2005/03/29 02:07:09 komatsu Exp $
#
# Copyright (C) 2002 - 2004 Hiroyuki Komatsu <komatsu@taiyaki.org>
#     All rights reserved.
#     This is free software with ABSOLUTELY NO WARRANTY.
#
# Modified by rusutaku
#
# You can redistribute it and/or modify it under the terms of 
# the GNU General Public License version 2.
#

#NOTE: obsolete
$KCODE = 'utf8'
require 'jcode'
require 'kconv'
#require 'suikyo/suikyo-config'
SUIKYO_TABLE_PATH = "./conv-table/"

class File
  def File::join2 (*paths)
    dirs = paths[0..-2].map{|path|
      path ? path.split(File::Separator) : ""
    }
    join(dirs, paths[-1])
  end
end

class Suikyo
  attr_reader :table
  def initialize (table = nil)
    if table.kind_of?(String) then
      @table = SuikyoTable2.new()
      @table.loadfile(table)
    elsif table then
      @table = table
    else
      @table = SuikyoTable2.new
    end
  end

  def convert (string, table = @table)
    (conversion, pending, last_node) = convert_internal(string, table)
    return conversion + pending
  end

  def expand (string, table = @table)
    (conversion, pending, last_node) = convert_internal(string, table)

    if last_node and last_node.subtable then
      suffixes = expand_table(last_node.subtable).push(pending).compact.uniq
      conversions = suffixes.map {|suffix|
        conversion + suffix
      }
    else
      conversions = [conversion + pending]
    end
    return [conversion + pending, conversions]
  end

  def convert_internal (string, table = @table)
    chars = string.split(//)
    orig_table = table
    conversion = ""

    loop {
      pending = ""
      table   = orig_table
      node    = nil

      while table and chars.length > 0 do
        head = chars[0]
        tmp_node = table.get_word(head)
        table = (tmp_node and tmp_node.subtable)
        if tmp_node or pending == "" then
          pending += head unless head == " "
          node = tmp_node
          chars.shift
        end
      end

      if table.nil? and node and (node.result or node.cont) then
        pending = ""
        if node.result then
          conversion += node.result
        end
        if node.cont then
          chars.unshift(node.cont)
        end
      end

      if chars.length == 0 then
        if table.nil? then
          return [conversion + pending, "", nil]
        else
          return [conversion, pending, node]
        end
      else
        conversion += pending
      end
    }
  end


  def valid? (string, table = @table)
    # Check a validness of string conversion.
    #   valid: "ringo" -> "りんご"
    # invalid: "apple" -> "あっplえ"
    (conversion, conversions) = expand(string, table)

    # Checking "appl -> あっpl" (invaild)
    if conversions.length == 1 and conversion !~ /^[a-zA-Z]*[^a-zA-Z]+$/ then
      return false
    end

    conversions.each {|word|
      if word =~ /^[^a-zA-Z]+([a-zA-Z]*)$/ then
        if $1.empty? then
          return true
        end
        (conversion2, conversions2) = expand($1, table)
        conversion2.each { | word2 |
          if word2 =~ /^[^a-zA-Z]+$/ then
            return true
          end
        }
      end
    }
    return false
  end

  private
  def expand_table (table)
    return [] unless table

    results = []
    table.allresults_uniq.each {|result, cont|
      if cont then
        subtable = @table.get_word(cont).subtable()
	if subtable then
	  subtable.allresults_uniq.each {|subresult, subcont|
	    results.push(result + subresult)
	  }
	else
	  results.push(result + cont)
	end
      else
	results.push(result)
      end
    }
    return results.uniq
  end
end

class TororoSuikyo < Suikyo
  attr_accessor :punctuation_marks

  def convert (string, table = @table, \
      strict = false, quote = false , trim = false)
    (conversion, pending, last_node) = convert_internal(string, table, strict, quote, trim)
    return conversion + pending
  end

  def convert_internal (string, table = @table, \
      strict = false, quote = false, trim = false)
    chars = string.split(//)
    orig_table = table
    conversion = ""
    head_bordered = true
    tail_bordered = false
    head = ""

    loop {
      orig_str  = ""
      quote_str = ""
      pending = ""
      table   = orig_table
      node    = nil
      last_node = nil # 最有力候補
      result  = ""
      candidate = []

      while table and chars.length > 0 do
        head = chars[0]
        tmp_node = table.get_word(head)
        table = (tmp_node and tmp_node.subtable)
        if tmp_node or pending == "" then
          unless head == " " and trim == true then
            pending += head
          end
          node = tmp_node
          orig_str += chars.shift
          # 現時点での最有力候補を発見
          if node and node.result then
            last_node = node
            result    = node.result
            # これ以降の候補が外れた時用の書き戻しを保存
            candidate = chars.clone
            quote_str = orig_str if quote
          end
        end
      end

      # 変換判定，処理の塊
      if table.nil? and \
        (node      and (     node.result or node.cont     )) or \
        (last_node and (last_node.result or last_node.cont)) then
        pending = ""
        if node.result or last_node.result then
          # strict: 語の途中で変換しない
          # i.e. (辞書)hobbit -> ホビット: (本文)hobbiton -> ホビットon
          #      のように変換対象の前後ともに区切り文字で分かれていない場合．
          if strict then
            if chars.length > 0 then
              tail_bordered = punctuation?(candidate[0])
            else
              # 変換対象文字列の一番後ろでぴったり変換できる場合
              # は後ろが区切られているのは確定
              tail_bordered = true if node.result
            end
            # 前後を区切られている？
            if head_bordered and tail_bordered then
              conversion += converted_result(result, quote_str, quote)
              # 変換してない文字を書き戻す
              chars = candidate if last_node.result
            else
              # 区切られてなかったら変換しない
              conversion += orig_str
            end
          else
            conversion += converted_result(result, quote_str, quote)
            # 変換してない文字を書き戻す
            chars = candidate if last_node.result
          end
        end
        if node.cont or last_node.cont then
          chars.unshift(node.cont)
        end
      end

      if chars.length == 0 then
        if table.nil? then
          return [conversion + pending, "", nil]
        else
          return [conversion, pending, node]
        end
      else
        conversion += pending
      end

      # ここの head は次の文字の先頭
      if punctuation?(head) then
        head_bordered = true
      else
        head_bordered = false
      end
    }
  end

  def converted_result(result_string, original_string, quote)
    if quote then
      return result_string + "[_#{original_string}_]"
    else
      return result_string
    end
  end

  # 区切り文字の判定
  def punctuation?(char)
    return true if char == ""
    return punctuation_marks =~ char
  end

end

# 改行対応
class TororoSuikyoMore < TororoSuikyo
  def initialize (table = nil)
    if table.kind_of?(String) then
      @table = SuikyoTable2More.new()
      @table.loadfile(table)
    elsif table then
      @table = table
    else
      @table = SuikyoTable2More.new
    end
  end
end

class SuikyoTable
  attr_reader :table_files

  def initialize
    @word = Hash.new()
    @table_files = []
  end

  def set (string, result, cont = nil, unescape = false) # false: 文字化け対策 
    if unescape then
      string = unescape(string)
      result = unescape(result)
      cont   = (cont and unescape(cont))
    end

    head = string.split(//)[0]
    rest = string.split(//)[1..-1].join
    @word[head] = SuikyoNode.new if @word[head].nil?

    if rest == "" then
      @word[head].result = result
      @word[head].cont   = cont
    else
      @word[head].subtable = self.class.new unless @word[head].subtable
      @word[head].subtable.set(rest, result, cont, false)
    end
  end

  ## This removes the string entry from the Suikyo table tree.
  ## If a child tree does not exist it returns ture.
  def unset (string)
    head = string.split(//)[0]
    rest = string.split(//)[1..-1].join()

    if @word[head].nil? then
      return true
    end

    if rest == "" then
      if @word[head].subtable.nil? or @word[head].subtable.allword.empty? then
        @word.delete(head)
        return true
      end

      @word[head].result = nil
      @word[head].cont   = nil
    else
      if @word[head].subtable then
        @word[head].subtable.unset(rest)
        if @word[head].subtable.allword.empty? then
          @word.delete(head)
          return true
        end
      end
    end
    return false
  end

  def loadfile (filename, tablepath = nil)
    filepath = SuikyoTable::loadpath(filename, tablepath)
    if FileTest::exist?(filepath) then
      @table_files.push(filepath)
    else
      $stderr.puts "Suikyo.rb: conv-table '#{filepath}' is not found."
      return false
    end

    comment_flag = false
    open(filepath, "r").readlines.each{|line|
      line.chomp!
      ## The function 'toeuc' converts half-width Katakana to full-width.
#      line = line.toeuc.chomp
      if line =~ /^\/\*/ then
	comment_flag = true
      end
      unless line =~ /^\#|^\s*$/ or comment_flag then
	(string, result, cont) = line.sub(/^ /, "").split(/\t/)
        if result.nil? then
          self.unset(string)
        else
          self.set(string, result, cont)
        end
      end
      if line =~ /\*\// then
	comment_flag = false
      end
    }
    return true
  end

  def SuikyoTable::loadpath (filename, tablepath = nil)
    if filename =~ /^\// then
      return filename
    else
      prefix = (tablepath or ENV['SUIKYO_TABLE_PATH'] or SUIKYO_TABLE_PATH)
      return File::join2(prefix, filename) 
    end
  end

  def get_word (chars)
    word  = nil
    words = allword()
    chars.split(//).each { | char |
      word = words[char]
      if word.nil? or word.subtable.nil? then
        break
      end
      words = word.subtable.allword
    }
    return word
  end

  def allword
    return @word
  end

  def allresults
    # c => [ち, ちゃ, ちゅ, ちょ]
    results = []
    allword.each {|char, table|
      if table.result then
	results.push([table.result, table.cont])
      end
      if table.subtable then
	results += table.subtable.allresults
      end
    }
    return results.uniq
  end

  def allresults_uniq
    # c => [ち]
    results = allresults.sort {|pair1, pair2|
      pair1[0] <=> pair2[0]
    }
    (base_result, base_cont) = results[0]
    uniq_results = [results[0]]

    results.each {|result, cont|
      unless result.index(base_result) == 0 and cont == base_cont then
	uniq_results.push([result, cont])
	base_result = result
	base_cont   = cont
      end
    }
    return uniq_results
  end

  private
  def unescape (string)
    unescaped_string = ""
    # IronRuby 0.9 ではUTF-8 で問題が出る（A5 が \ に誤認される）
    while (index = string.index('\\')) do
      next_char = string[index + 1,1]
      case next_char
      when "x" then
        hex_string = string[index + 2,2]
        if hex_string =~ /^[a-zA-F0-9][a-zA-F0-9]$/ then
          unescaped_string += string[0,index] + hex_string.hex.chr
          string = (string[index + 4..-1] or "")
        else
          $stderr.puts "Suikyo: Unescape error from \"#{string}\"."
          unescaped_string += string[0,index] + '\\'
          string = (string[index + 1..-1] or "")
        end
      when "0" then
	unescaped_string += string[0,index]
	string = (string[index + 2..-1] or "")
      else
	unescaped_string += string[0,index] + next_char
	string = (string[index + 2..-1] or "")
      end
    end
    return unescaped_string + string
  end

  private
  class SuikyoNode
    attr_accessor :subtable, :cont, :result
    def initialize (result = nil, cont = nil, subtable = nil)
      @result   = result
      @cont     = cont
      @subtable = subtable
    end
  end
end

class SuikyoTable2 < SuikyoTable
  def get_word (chars)
    word  = nil
    words = allword()
    chars.split(//).each { | char |
      word = words[char]
      if word.nil? then
        word = words[char.swapcase]
      end
      if word.nil? or word.subtable.nil? then
        break
      end
      words = word.subtable.allword
    }
    return word
  end
end

# 改行対応
# 一行目を改行用文字列として，データ内の改行用文字列を改行コードに置き換える
class SuikyoTable2More < SuikyoTable2
  def loadfile (filename, tablepath = nil)
    filepath = SuikyoTable::loadpath(filename, tablepath)
    if FileTest::exist?(filepath) then
      @table_files.push(filepath)
    else
      $stderr.puts "Suikyo.rb: conv-table '#{filepath}' is not found."
      return false
    end

    comment_flag = false

    lines = open(filepath, "r").readlines

    # 改行のおまじないを読んでみる
    newline_string = ""
    magic_line = lines[0]
    unless magic_line =~ /\t/ then
      magic_line.chomp!
      unless magic_line =~ /^\#|^\s*$/ then
        newline_string = magic_line
        lines.slice!(0)
      end
    end

    lines.each{|line|
      line.chomp!
      ## The function 'toeuc' converts half-width Katakana to full-width.
      #      line = line.toeuc.chomp
      if line =~ /^\/\*/ then
        comment_flag = true
      end
      unless line =~ /^\#|^\s*$/ or comment_flag then
        (string, result, cont) = line.sub(/^ /, "").split(/\t/)
        if result.nil? then
          self.unset(string)
        else
          if newline_string.length > 0 then
            result.gsub!(newline_string, "\r\n")
          end
          self.set(string, result, cont)
        end
      end
      if line =~ /\*\// then
        comment_flag = false
      end
    }
    return true
  end
end

require 'rubygems'
require 'rainbow'

# Some common utlities for dealing with CRISPR data
module Crispr
  
  # The CRISPR colorizer takes a collection of colors, attempts to assemble 
  # them into legible foregrand and background combinations, and returns
  # unique color combinations for unique keys until the collection of color
  # combinations has been exhausted.
  class Colorizer
    COLORS = [:black, :red, :green, :yellow, :blue, :magenta, :cyan, :white]
    EXCEL_COLORS = [
      :brown, :gray, :lime, :navy, :orange, :purple, :silver
    ] + COLORS
    
    attr_accessor :colors, :combos, :colormap
    
    def initialize(options = {})
      @colors = options[:colors] || COLORS
      @combos = options[:combos] || comboize(@colors)
      @colormap = if options[:colormap]
        @colors, @combos = [], []
        options[:colormap]
      else
        {}
      end
    end
    
    def comboize(colors)
      combos = []
      colors.each do |c|
        unless c == :black || c == :white
          combos << [c]
        end
        colors.each do |b|
          next if c == b || (c == :white || b == :black)
          next if c == :yellow && b == :white
          next if c == :cyan && b == :white
          next if c == :cyan && b == :lime
          next if c == :red && b == :magenta
          next if c == :magenta && b == :red
          combos << [c,b] 
        end
      end
      combos
    end

    def color_combo_for(key, options = {})
      # remove parenteses indicating a guess insertion
      key = key.gsub(/\((.*?)\)/, "\\1").strip
      
      # remove instance number, so all group_1-1 and group_1-1 get colored the same
      key = key.gsub(/\-\d+$/, '').strip
      
      @colormap[key] || @colormap[key] = @combos.pop
    end

    # colors unique strings with unique colors for ANSI terminal output
    def colorize(str, options = {})
      key = (options[:key] || str).strip
      color, bg, underline = @colormap[key]
      if color && Sickill::Rainbow::TERM_COLORS.keys.include?(color.to_sym)
        return color_and_bg(str, color, bg)
      end
      @colormap[key] = color_combo_for(key)
      color, bg, underline = @colormap[key]
      return str unless color
      color_and_bg(str, color, bg)
    end
  end
  
  def color_and_bg(str, color, bg = nil)
    return str unless Sickill::Rainbow::TERM_COLORS.keys.include?(color.to_sym)
    return str.color(color.to_sym) unless bg && Sickill::Rainbow::TERM_COLORS.keys.include?(bg.to_sym)
    str.color(color.to_sym).background(bg.to_sym)
  end
  
  # parses an array of crispr data: sample identifier, count, *groups
  def parse_line(line)
    return nil unless sample = line[0]
    sample = line[0]
    locus, ratio, timepoint = sample.scan(/CR_(\d+)_MOI(\d+)_tp_(\d+)/).first
    count = line[1]
    groups = line[2..-1].compact
    [sample, locus, ratio, timepoint, count, groups]
  end
end

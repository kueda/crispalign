require 'rubygems'
require 'fastercsv'
require 'trollop'
require 'spreadsheet'
require 'json'
require 'active_support/core_ext/enumerable'
require 'active_support/core_ext/object/blank'
require File.dirname(__FILE__) + '/crispr.rb'
include Crispr

OPTS = Trollop::options do
  version "0.1"
  banner <<-EOT
Convert CRISPR spacer groups into naively aligned, colorized output.  Assumes 
unaligned TAB-delimited input in the following format:

  sample    count    group1:group2:[...]:groupN

It will also parse a CSV file if it ends in .csv and has the format:

  sample,count,group1,group2,[...],groupN
  
Locus, ratio, and timepoint filtering assume the sample is named using the 
following pattern:

  CR_[LOCUS]_MOI[RATIO]_tp_[TIMEPOINT]

where LOCUS, RATIO, and TIMEPOINT are integers. 

The script aligns spacer groups based on the frequency with which they follow
other groups. For example, if the script encounters a sample with group F and
nothing preceding it, but group F follows group Q 2 times and group Z 10
times in the entire dataset, then the script will assume group Z was not
included in the sample and align group F with instances of group F in other
samples where it follows group Z.

Usage:
  # output to console
  ruby crispalign.rb filename.csv 
  
  # output to an Excel spreadsheet named filename.xls
  ruby crispalign.rb filename.csv --format=xls
  
Options:
EOT
  
  opt :outfile, "Output filename", :type => String, :short => "-o"
  opt :format, "Output format", :type => String, :short => "-f"
  opt :locus, "Locus number", :type => Integer, :short => "-l"
  opt :ratio, "Ratio", :type => Integer, :short => "-r"
  opt :timepoint, "Timepoint", :type => Integer, :short => "-t"
  opt :numcols, "Number of group columns", :type => Integer, :short => "-n", :default => 6
  opt :colwidth, "Column width (for console output)",  :type => Integer, :short => "-w", :default => 15
  opt :colors, "Read/write colors from/to this file",  :type => String, :short => "-c"
  opt :sort, "Sorts results, only options is 'group' for now",  :type => String, :short => "-s"
end

unless ARGV[0]
  Trollop::die "You must specify an input file"
end

def setup_colorizer
  # Set up the colorizer
  colorizer = if OPTS[:colors]
    begin
      colorfile = open(OPTS[:colors])
      json = JSON.parse(colorfile.read())
    rescue Errno::ENOENT, JSON::ParserError
      colorfile = open(OPTS[:colors], 'w')
      json = {}
    end
    Crispr::Colorizer.new(:colormap => json) unless json.empty?
  end
  colorizer ||= if OPTS[:format] == 'xls'
    Crispr::Colorizer.new(:colors => Crispr::Colorizer::EXCEL_COLORS)
  else
    Crispr::Colorizer.new
  end
  colorizer
end

# Add an IO-like << method to the Worksheet class that just adds an array of 
# cells as a new row
class Spreadsheet::Worksheet
  attr_accessor :frequencies
  
  def <<(cells)
    return if cells.compact.empty?
    first_used_row, first_unused_row = dimensions
    idx = first_unused_row || 0
    row = Spreadsheet::Row.new(self, idx, cells)
    @rows.insert(idx, row)
    updated_from idx
    
    # Colorize group cells
    row.each_with_index do |cell, i|
      row[i] = '' if cell == '*'
      if cell =~ /\(.*?\)/
        row[i] = if row[i+1..-1].detect{|fc| fc !~ /\(.*?\)/}
          '*'
        else
          ''
        end
      end
      row[i] = '-' if cell =~ /^\-/
      next unless cell =~ /group_/
      fg, bg = if %w(- *).include?(cell) || @frequencies[cell].to_i == 1
        [nil, nil]
      else
        COLORIZER.color_combo_for(cell)
      end
      @fmt_cache ||= {}
      unless fmt = @fmt_cache["#{fg}#{bg}"]
        fmt = Spreadsheet::Format.new
        fmt.font.color = fg unless fg.nil?
        unless bg.nil?
          fmt.pattern = 1
          fmt.pattern_fg_color = bg
        end
        @fmt_cache["#{fg}#{bg}"] = fmt
      end
      row.set_format(i, fmt) if fg || bg
    end
  end
end

# Determines what instance name to use for a group
def instance_name_for(group, options = {})
  instance_name = group
  instance_name = instance_name.gsub(/\((.*?)\)/, "\\1").strip
  instance_name = "-" if instance_name.blank?
  return instance_name if @frequencies[group] == 1
  prev = (options[:prev] || '').strip.gsub(/\((.*?)\)/, "\\1").strip
  @instances ||= {}
  @instances[group] ||= {}
  instance_name = @instances[group][prev] ||= instance_name + "-#{@instances[group].size + 1}"
  instance_name
end

# Returns an array of the highest probability previous groups for a given
# group, based on frequency.  Builds the most probable sequence of previous
# groups by recursively finding the most probable previous group.  Example: 
# if group2 followed group1 5 times and followed group3 6 times, 
# prev_groups_for(group2) would be [group3].
def prev_groups_for(group)
  return [] if @prev_frequencies.blank? || @prev_frequencies[group].blank?
  prev_freqs = @prev_frequencies[group].sort_by(&:last)
  best_prev, best_prev_count = prev_freqs.last
  return [] if best_prev == group || best_prev == ''
  prev_groups_for(best_prev) + [best_prev]
end

# Builds hashes of group frequencies given a CSV path
def calculate_frequencies(path)
  @frequencies ||= {}
  @prev_frequencies ||= {} # :group => {:prev_group => count}
  
  # score is the absolute number of reads in which prev preceded group, as 
  # opposed to the unique reads, similar to @frequencies but summing read
  # counts instead.  We want abundant reads to count more.
  @prev_scores ||= {}
  
  read(path) do |line|
    next unless parsed_line = parse_line(line)
    sample, locus, ratio, timepoint, count, groups = parsed_line
    next unless OPTS[:locus].nil? || locus.to_i == OPTS[:locus]
    next unless OPTS[:ratio].nil? || ratio.to_i == OPTS[:ratio]
    next unless OPTS[:timepoint].nil? || timepoint.to_i == OPTS[:timepoint]
    
    groups = groups.reverse
    groups.each_with_index do |group, i|
      @frequencies[group] = @frequencies[group].to_i + 1
      prev_group = i == 0 ? '' : groups[i-1]
      @prev_frequencies[group] ||= {}
      @prev_scores[group] ||= {}
      @prev_frequencies[group][prev_group] = @prev_frequencies[group][prev_group].to_i + 1
      @prev_scores[group][prev_group] = @prev_scores[group][prev_group].to_i + count.to_i
    end
  end
end

# Performs the actual alignment
def align_groups(line)
  return unless parsed_line = parse_line(line)
  sample, locus, ratio, timepoint, count, groups = parsed_line
  groups = groups.reverse
  group_strings = []
  
  groups.each_with_index do |group, i|
    # calculate most probable previous groups
    best_prev_groups = prev_groups_for(group).reverse
    
    # excise the actual previous groups in this read
    prev_groups = groups[0...i].reverse
    
    # extend the groups with the most probable previous groups if the actual 
    # prev groups form a subset of the most probable prev groups
    extension = []
    extension_needed = (prev_groups - best_prev_groups).size == 0
    if extension_needed
      best_prev_groups.each_with_index do |best_prev, j|
        prev = prev_groups[j]
        break if prev_groups.index(best_prev) || group_strings.index(best_prev) || group_strings.index("(#{best_prev})")
        next if best_prev == prev
        prev_best_prev = best_prev_groups[j+1] || ''
        extension << "(#{best_prev})" unless best_prev == ''
      end
      extension.reverse.each_with_index do |g,i|
        prev = i == 0 ? '' : extension[i-1]
        group_strings << g
      end
    end
    prev = extension.first || group_strings.last
    group_strings << group
  end
  
  # aply instance name labels
  group_strings.each_with_index do |group, i|
    prev = i == 0 ? nil : group_strings[i-1]
    group_strings[i] = if group =~ /\(.*?\)/
      "(#{instance_name_for(group, :prev => prev)})"
    else
      instance_name_for(group, :prev => prev)
    end
  end
  
  begin
    group_strings += ['*'] * (OPTS[:numcols]-group_strings.size)
  rescue ArgumentError => e
    raise e unless e.message =~ /negative argument/
    Trollop::die "Oops, not enough cols.  Please try a higher --numcols value"
  end
  [sample, count, *group_strings.reverse]
end

# Output results to file or console
def write
  case OPTS[:format]
  when 'xls'
    worksheet = Spreadsheet::Worksheet.new(:workbook => Spreadsheet::Workbook.new)
    worksheet.frequencies = @frequencies
    @out.each do |row|
      worksheet << row
    end
    book = worksheet.workbook
    fname = OPTS[:outfile] || "#{File.basename(ARGV[0], '.csv')}.xls"
    path = File.join File.dirname(ARGV[0]), fname
    book.add_worksheet(worksheet)
    book.write path
    puts "Wrote output to #{fname}"
  when 'csv'
    fname = OPTS[:outfile] || "#{File.basename(ARGV[0], '.csv')}.aligned.csv"
    path = File.join File.dirname(ARGV[0]), fname
    FasterCSV.open(path, 'w') do |csv|
      @out.each do |row|
        next if row.blank?
        csv << row
      end
    end
  else
    @out.each do |line|
      next if line.nil?
      sample, locus, ratio, timepoint, count, groups = parse_line(line)
      line_str = "#{sample.ljust(20)}#{count.ljust(10)}"
      groups.each_with_index do |g, i|
        line_str << if g.nil? || g == '*'
          ''.center(OPTS[:colwidth])
        elsif %w(- *).include?(g)
          g.center(OPTS[:colwidth]) 
        elsif g =~ /^\-/
          '-'.center(OPTS[:colwidth])
        elsif @frequencies[g].to_i == 1
          g.ljust(OPTS[:colwidth])
        elsif g =~ /\((.*?)\)/
          # Only show stars for interior gaps
          if groups[i+1..-1].detect{|fg| fg !~ /\(.*?\)/}
            COLORIZER.colorize('*'.center(OPTS[:colwidth]), :key => g)
          else
            COLORIZER.colorize(''.center(OPTS[:colwidth]), :key => g)
          end
        else
          COLORIZER.colorize(g.ljust(OPTS[:colwidth]))
        end
      end
      puts line_str
    end
    
    puts "DONE!"
  end
end

# Sort rows by position and abundance of all groups
def sort_by_groups(rows)
  @frequencies ||= {}
  rows.sort do |a,b|
    if a.nil? && b.nil?
      0
    elsif a.nil?
      1
    elsif b.nil?
      -1
    else
      line_a, line_b = [parse_line(a), parse_line(b)]
      groups_a, groups_b = [line_a.last, line_b.last]
      groups_a = groups_a.map{|g| g.gsub(/\((.*?)\)/, "\\1").strip}
      groups_b = groups_b.map{|g| g.gsub(/\((.*?)\)/, "\\1").strip}
      freq_sum_a = groups_a.map{|g| @frequencies[g].to_i}.sum
      freq_sum_b = groups_b.map{|g| @frequencies[g].to_i}.sum
      [groups_b.reverse, freq_sum_b] <=> [groups_a.reverse, freq_sum_a]
    end
  end
end

def read(path)
  if path =~ /\.csv$/
    FasterCSV.foreach(path) do |line|
      yield(line)
    end
  else
    open(path).each_line do |linestr|
      line = linestr.split("\t").map do |col|
        col.strip.split(':')
      end.flatten
      yield(line)
    end
  end
end

if __FILE__ == $0
  # Set the output "stream"
  @out = []
  case OPTS[:format]
  when 'xls'
    header, footer = %w(sample count), []
  else
    @out = []
    header, footer = nil, nil
  end
  
  COLORIZER = setup_colorizer
  
  # Calculate frequencies of groups and pairs of groups
  calculate_frequencies(ARGV[0])

  # Loop over all lines in the input
  read(ARGV[0]) do |line|
    unless parsed_line = parse_line(line)
      @out << line
      next
    end
    sample, locus, ratio, timepoint, count, groups = parsed_line
    next unless OPTS[:locus].nil? || locus.to_i == OPTS[:locus]
    next unless OPTS[:ratio].nil? || ratio.to_i == OPTS[:ratio]
    next unless OPTS[:timepoint].nil? || timepoint.to_i == OPTS[:timepoint]
    @out << align_groups(line)
  end

  # sorting
  @out = sort_by_groups(@out) if %w(group groups).include?(OPTS[:sort])

  @out.insert(0, header)
  @out << footer
  write

  if OPTS[:colors] && json.empty?
    puts "Writing colorfile..."
    colorfile.write(JSON.pretty_generate(COLORIZER.colormap))
    colorfile.close
  end
end


crispalign
==========

This script aligns [CRISPR](http://en.wikipedia.org/wiki/CRISPR) spacer groups
based on the frequency with which they follow other groups. For example, if
the script encounters a sample with group F and nothing preceding it, but
group F follows group Q 2 times and group Z 10 times in the entire dataset,
then the script will assume group Z was not included in the sample and align
group F with instances of group F in other samples where it follows group Z.

INSTALLATION
============================================================================
1. install ruby: [http://www.ruby-lang.org/](http://www.ruby-lang.org/)
2. install rubygems: [http://rubygems.org/](http://rubygems.org/)
3. install gem dependencies: `gem install fastercsv trollop spreadsheet json active_support`


USAGE
============================================================================

Make sure crispr.rb and crispalign.rb are in the same directory. Input data 
should be unaligned TAB-delimited data in the following format:

    sample    count    group1:group2:[...]:groupN

The script will also parse a CSV file if it ends in .csv and has the format:

    sample,count,group1,group2,[...],groupN
  
Locus, ratio, and timepoint filtering assume the sample is named using the 
following pattern:

    CR_[LOCUS]_MOI[RATIO]_tp_[TIMEPOINT]

where LOCUS, RATIO, and TIMEPOINT are integers.

    # output to console
    ruby crispalign.rb filename.csv 

    # output to an Excel spreadsheet named filename.xls
    ruby crispalign.rb filename.csv --format=xls

For more available filters and options, run

    ruby crispalign.rb --help

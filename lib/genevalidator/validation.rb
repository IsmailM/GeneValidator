#!/usr/bin/env ruby

require 'genevalidator/blast'
require 'genevalidator/output'
require 'genevalidator/exceptions'
require 'genevalidator/tabular_parser'
require 'genevalidator/validation_length_cluster'
require 'genevalidator/validation_length_rank'
require 'genevalidator/validation_blast_reading_frame'
require 'genevalidator/validation_gene_merge'
require 'genevalidator/validation_duplication'
require 'genevalidator/validation_open_reading_frame'
require 'genevalidator/validation_alignment'
require 'bio-blastxmlparser'
#require 'rinruby'
require 'net/http'
require 'open-uri'
require 'uri'
require 'io/console'
require 'yaml'

class Validation

  attr_reader :type
  attr_reader :fasta_filepath
  attr_reader :html_path
  attr_reader :yaml_path
  attr_reader :mafft_path
  attr_reader :filename
  # current number of the querry processed
  attr_reader :idx
  attr_reader :start_idx
  #array of indexes for the start offsets of each query in the fasta file
  attr_reader :query_offset_lst

  attr_reader :vlist
  attr_reader :tabular_format

  ##
  # Initilizes the object
  # Params:
  # +fasta_filepath+: query sequence fasta file with query sequences
  # +type+: query sequence type; can be :nucleotide or :protein
  # +xml_file+: name of the precalculated blast xml output (used in 'skip blast' case)
  # +vlist+: list of validations
  # +start_idx+: number of the sequence from the file to start with
  def initialize(fasta_filepath, vlist = ["all"], tabular_format = nil, xml_file = nil, mafft_path = nil, start_idx = 1)
    begin

      @fasta_filepath = fasta_filepath
      @xml_file = xml_file
      @vlist = vlist.map{|v| v.gsub(/^\s/,"").gsub(/\s\Z/,"").split(/\s/)}.flatten
      @idx = 0

      if start_idx == nil
        @start_idx = 1
      else
        @start_idx = start_idx
      end

      raise FileNotFoundException.new unless File.exists?(@fasta_filepath)
      fasta_content = IO.binread(@fasta_filepath);

      # the expected type for the sequences is the
      # type of the first query
       
      # type validation: the type of the sequence in the FASTA correspond to the one declared by the user
      @type = BlastUtils.type_of_sequences(fasta_content)

      # create a list of index of the queries in the FASTA
      @query_offset_lst = fasta_content.enum_for(:scan, /(>[^>]+)/).map{ Regexp.last_match.begin(0)}
      @query_offset_lst.push(fasta_content.length)
      fasta_content = nil # free memory for variable fasta_content
      @tabular_format = tabular_format

      if mafft_path == nil
        @mafft_path = which("mafft")
      else
        @mafft_path = mafft_path
      end
   
      # build path of html folder output
      path = File.dirname(@fasta_filepath)#.scan(/(.*)\/[^\/]+$/)[0][0]
      if path == nil
        @html_path = "html"
      else
        @html_path ="#{path}/html"
      end
      @yaml_path = path

      @filename = File.basename(@fasta_filepath)#.scan(/\/([^\/]+)$/)[0][0]

      # create 'html' directory
      FileUtils.rm_rf(@html_path)
      Dir.mkdir(@html_path)

      # copy auxiliar folders to the html folder
      FileUtils.cp_r("aux/css", @html_path)
      FileUtils.cp_r("aux/js", @html_path)
      FileUtils.cp_r("aux/img", @html_path)
      FileUtils.cp_r("aux/font", @html_path)

    rescue SequenceTypeError => error
      $stderr.print "Sequence Type error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: input file is not FASTA or the --type parameter is incorrect.\n"      
      exit
    rescue FileNotFoundException => error
      $stderr.print "File not found error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: input file does not exist.\n"
      exit 
    end
  end

  ##
  # Calls blast according to the type of the sequence
  def validation
    puts "\nDepending on your input and your computational resources, this may take a while. Please wait..."
    begin
      if @xml_file == nil
 
        #file seek for each query
        @query_offset_lst[0..@query_offset_lst.length-2].each_with_index do |pos, i|
      
          if (i+1) >= @start_idx
            query = IO.binread(@fasta_filepath, @query_offset_lst[i+1] - @query_offset_lst[i], @query_offset_lst[i]);

            #call blast with the default parameters
            if type == :protein
              output = BlastUtils.call_blast_from_stdin("blastp", query, 11, 1)
            else
              output = BlastUtils.call_blast_from_stdin("blastx", query, 11, 1)
            end

            #save output in a file
            xml_file = "#{@fasta_filepath}_#{i+1}.xml"
            File.open(xml_file , "w") do |f| f.write(output) end

            #parse output
            parse_xml_output(output)   
          else
            @idx = @idx + 1
          end
        end
      else
        file = File.open(@xml_file, "rb").read
        #check the format of the input file
        parse_xml_output(file)      
      end

    rescue SystemCallError => error
      $stderr.print "Load error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: input file is not valid\n"      
      exit
    end
  end

  ##
  # Parses the xml blast output 
  # Param:
  # +output+: +String+ with the blast output in xml format
  def parse_xml_output(output)
    
    iterator_xml = Bio::BlastXMLParser::NokogiriBlastXml.new(output).to_enum
    iterator_tab = TabularParser.new(output, tabular_format, @type)

    begin
      @idx = @idx + 1
      begin
        # check xml format
        if @idx < @start_idx
          iter = iterator_xml.next
        else
          hits = BlastUtils.parse_next_query_xml(iterator_xml, @type)
          if hits == nil
            @idx = @idx -1
            break
          end
          do_validations(hits)
        end

      rescue Exception => error
        if tabular_format == nil and xml_file!= nil
          puts "Note: Please specify the --tabular argument if you used tabular format input with nonstandard columns\n"
        end

        #check tabular format 
        if @idx < @start_idx
          iterator_tab.next          
        else

          hits = iterator_tab.next
          if hits == nil
            @idx = @idx -1
            break
          end
          do_validations(hits)
        end
      end

      rescue Exception => error
        $stderr.print "Blast input error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: blast input is neither xml nor tabular.\nPossible cause 2: If you didn't use stadard tabular outformat please provide -tabular argument with the format of the columns\n"
        exit
    end while 1

  end

  def remove_identical_hits(prediction, hits)
    # remove the identical hits
    # identical hit means 100%coverage and >99% identity
    identical_hits = []
    hits.each do |hit|
      # check if all hsps have identity more than 99%
      low_identity = hit.hsp_list.select{|hsp| hsp.pidentity == nil  or hsp.pidentity < 99}
      # check the coverage
      coverage = Array.new(prediction.xml_length,0)
      hit.hsp_list.each do |hsp| 
         len = hsp.match_query_to - hsp.match_query_from + 1 
         coverage[hsp.match_query_from-1..hsp.match_query_to-1] = Array.new(len, 1)
      end
      if low_identity.length == 0 and coverage.uniq.length == 1
        identical_hits.push(hit)
      end
    end

    identical_hits.each {|hit| hits.delete(hit)}

    return hits
  end
  
  ##
  # Runs all the validations and prints the outputs given the current
  # prediction query and the corresponding hits
  def do_validations(hits)
    begin
    prediction = Sequence.new

    # get info about the query
    # get the @idx-th sequence  from the fasta file
    i = @idx-1
    query = IO.binread(@fasta_filepath, @query_offset_lst[i+1] - @query_offset_lst[i], @query_offset_lst[i])
    parse_query = query.scan(/>([^\n]*)\n([A-Za-z\n]*)/)[0]

    prediction.definition = parse_query[0].gsub("\n","")
    prediction.seq_type = @type
    prediction.raw_sequence = parse_query[1].gsub("\n","")
    prediction.xml_length = prediction.raw_sequence.length
   
    begin 
      hits = remove_identical_hits(prediction, hits)
      rescue Exception #NoPIdentError 
    end 
    if @type == :nucleotide
      prediction.xml_length /= 3
    end
    
    # do validations
    begin

      query_output = Output.new(@filename, @html_path, @yaml_path, @idx, @start_idx)
      query_output.prediction_len = prediction.xml_length
      query_output.prediction_def = prediction.definition
      query_output.nr_hits = hits.length

      plot_path = "#{html_path}/#{filename}_#{@idx}"

      validations = []
      validations.push LengthClusterValidation.new(@type, prediction, hits, plot_path)
      validations.push LengthRankValidation.new(@type, prediction, hits)
      validations.push BlastReadingFrameValidation.new(@type, prediction, hits)
      validations.push GeneMergeValidation.new(@type, prediction, hits, plot_path)
      validations.push DuplicationValidation.new(@type, prediction, hits, @mafft_path)
      validations.push OpenReadingFrameValidation.new(@type, prediction, hits, plot_path, ["ATG"])
      validations.push AlignmentValidation.new(@type, prediction, hits, plot_path, @mafft_path)

      # check the class type of the elements in the list
      validations.map do |v|
        raise ValidationClassError unless v.is_a? ValidationTest
      end

      # check alias duplication
      unless validations.map{|v| v.cli_name}.length == validations.map{|v| v.cli_name}.uniq.length
        raise AliasDuplicationError 
      end

      if vlist.map{|v| v.strip.downcase}.include? "all"
        validations.map{|v| v.run}
        # check the class type of the validation reports
        validations.each do |v|
          raise ReportClassError unless v.validation_report.is_a? ValidationReport
        end
        query_output.validations = validations
      else
        desired_validations = validations.select {|v| vlist.map{|vv| vv.strip.downcase}.include? v.cli_name.downcase }
        desired_validations.each do |v|
            v.run
            raise ReportClassError unless v.validation_report.is_a? ValidationReport
        end
        query_output.validations = desired_validations
        if query_output.validations.length == 0
          raise NoValidationError
        end
      end

    rescue ValidationClassError => error
      $stderr.print "Class Type error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: type of one of the validations is not ValidationTest\n"
      exit!
    rescue NoValidationError => error
      $stderr.print "Validation error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: your -v arguments are not valid aliases\n"
      exit!
    rescue ReportClassError => error
      $stderr.print "Class Type error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: type of one of the validation reports returned by the 'run' method is not ValidationReport\n"
      exit!
    rescue AliasDuplicationError => error
      $stderr.print "Alias Duplication error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: At least two validations have the same CLI alias\n"
      exit!
    rescue Exception => error
      $stderr.print "Error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}.\n"
      exit!
    end
 
    query_output.generate_html
    query_output.print_output_console
    query_output.print_output_file_yaml
  rescue Exception => error
    $stderr.print "Error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}.\n"
  end

  end

  def which(cmd)
    exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
    ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
      exts.each { |ext|
        exe = File.join(path, "#{cmd}#{ext}")
        return exe if File.executable? exe
      }
    end
    return nil
  end

end


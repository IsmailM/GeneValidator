require 'genevalidator/validation_output'
require 'genevalidator/exceptions'
require 'rinruby'

##
# Class that stores the validation output information
class DuplciationValidationOutput < ValidationReport

  attr_reader :pvalue
  attr_reader :threshold

  def initialize (pvalue, threshold = 0.05, expected = :no)
    @pvalue = pvalue
    @threshold = threshold
    @result = validation
    @expected = expected
  end

  def print
    "pval=#{@pvalue.round(2)}"
  end

  def validation
    if @pvalue < @threshold
      :yes
    else
      :no
    end
  end

  def color
    if validation == :no
      "success"
    else
      "danger"
    end
  end
end

##
# This class contains the methods necessary for
# finding duplicated subsequences in the predicted gene
class DuplicationValidation < ValidationTest

  attr_reader :mafft_path
 
  def initialize(type, prediction, hits, mafft_path)
    super
    @mafft_path = mafft_path
    @short_header = "Duplication"
    @header = "Duplication"
    @description = "Check whether there is a duplicated subsequence in the"<<
    " predicted gene by counting the hsp residue coverag of the prediction,"<<
    " for each hit. Meaning of the output displayed: P-value of the Wilcoxon"<<
    " test which test the distribution of hit average coverage against 1."<<
    " P-values higher than 5% pass the validation test."
    @cli_name = "dup"
    # redirect the cosole messages of R
    R.echo "enable = nil, stderr = nil, warn = nil"

  end

  ##
  # Check duplication in the first n hits
  # Output:
  # +DuplciationValidationOutput+ object
  def run(n=10)    
    begin
      raise NotEnoughHitsError unless hits.length >= 5
      raise Exception unless prediction.is_a? Sequence and
                             prediction.raw_sequence != nil and 
                             hits[0].is_a? Sequence 

      # get the first n hits
      less_hits = @hits[0..[n-1,@hits.length].min]

      begin
        # get raw sequences for less_hits
        less_hits.map do |hit|
          #get gene by accession number
          if hit.raw_sequence == nil
            if hit.seq_type == :protein
              hit.get_sequence_by_accession_no(hit.accession_no, "protein")
            else
              hit.get_sequence_by_accession_no(hit.accession_no, "nucleotide")
            end
          end
        end
        rescue Exception => error
          raise NoInternetError
      end
      averages = []

      less_hits.each do |hit|

        coverage = Array.new(hit.xml_length,0)
        hit.hsp_list.each do |hsp|

        # align subsequences from the hit and prediction that match (if it's the case)
          if hsp.hit_alignment != nil and hsp.query_alignment != nil
            hit_alignment = hsp.hit_alignment
            query_alignment = hsp.query_alignment
          else
            #get gene by accession number
            if hit.raw_sequence == nil
              if hit.seq_type == :protein
                hit.get_sequence_by_accession_no(hit.accession_no, "protein")
              else
                hit.get_sequence_by_accession_no(hit.accession_no, "nucleotide")
              end
            end

            # indexing in blast starts from 1
            hit_local = hit.raw_sequence[hsp.hit_from-1..hsp.hit_to-1]
            query_local = prediction.raw_sequence[hsp.match_query_from-1..hsp.match_query_to-1]

            # in case of nucleotide prediction sequence translate into protein
            # use translate with reading frame 1 because 
            # to/from coordinates of the hsp already correspond to the 
            # reading frame in which the prediction was read to match this hsp 
            if @type == :nucleotide
              s = Bio::Sequence::NA.new(query_local)
              query_local = s.translate
            end

            # local alignment for hit and query
            seqs = [hit_local, query_local]

            begin
              options = ['--maxiterate', '1000', '--localpair', '--quiet']
              mafft = Bio::MAFFT.new(@mafft_path, options)
              report = mafft.query_align(seqs)
              raw_align = report.alignment
              align = []
              raw_align.each { |s| align.push(s.to_s) }
              hit_alignment = align[0]
              query_alignment = align[1]
            rescue Exception => error                
              raise NoMafftInstallationError
            end
          end 

          # check multiple coverage

          # for each hsp of the curent hit
          # iterate through the alignment and count the matching residues
          [*(0 .. hit_alignment.length-1)].each do |i|
            residue_hit = hit_alignment[i]
            residue_query = query_alignment[i]
            if residue_hit != ' ' and residue_hit != '+' and residue_hit != '-'
              if residue_hit == residue_query             
                # indexing in blast starts from 1
                idx = i + (hsp.hit_from-1) - hit_alignment[0..i].scan(/-/).length 
                #puts "#{coverage.length} #{idx}"
                  coverage[idx] += 1
                #end
              end
            end
          end
        end
        overlap = coverage.reject{|x| x==0}
        averages.push(overlap.inject(:+)/(overlap.length + 0.0)).map{|x| x.round(2)}
      end
    
      # if all hsps match only one time
      if averages.reject{|x| x==1} == []
        @validation_report = DuplciationValidationOutput.new(1)
        return @validation_report
      end

      pval = wilcox_test(averages)

      #make the wilcox-test and get the p-value
      #R.eval("coverageDistrib = c#{averages.to_s.gsub('[','(').gsub(']',')')}")
      #R. eval("pval = wilcox.test(coverageDistrib - 1)$p.value")

      #pval = R.pull "pval"

      @validation_report = DuplciationValidationOutput.new(pval)        

      return @validation_report

    # Exception is raised when blast founds no hits
    rescue  NotEnoughHitsError => error
      @validation_report = ValidationReport.new("Not enough evidence", :warning)
      return @validation_report
    rescue NoMafftInstallationError
      @validation_report = ValidationReport.new("Unexpected error", :error)
      @validation_report.errors.push "[Duplication Validation] Mafft path installation exception. Please provide a correct instalation path"                          
      return @validation_report
    rescue NoInternetError
      @validation_report = ValidationReport.new("Unexpected error", :error)
      @validation_report.errors.push "[Duplication Validation] Connection to internat fail. Unable to retrieve raw sequences"
      return @validation_report
    else
      @validation_report = ValidationReport.new("Unexpected error", :error)
      return @validation_report
    end
  end

  ##
  # Calls R to calculate the p value for the wilcoxon-test
  # Input
  # +vector+ Array of values with nonparametric distribution
  def wilcox_test (averages)
    begin
      #make the wilcox-test and get the p-value
      R.eval("coverageDistrib = c#{averages.to_s.gsub('[','(').gsub(']',')')}")
      R. eval("pval = wilcox.test(coverageDistrib - 1)$p.value")

      pval = R.pull "pval"
      return pval
    rescue Exception => error
      #return nil
    end
  end
end
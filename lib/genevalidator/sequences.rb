require 'net/http'

class Sequence

  attr_accessor :seq_type #protein | mRNA
  attr_accessor :id
  attr_accessor :definition
  attr_accessor :species
  attr_accessor :accession_no
  attr_accessor :xml_length
  attr_accessor :reading_frame
  attr_accessor :hsp_list # array of Hsp objects 
 
  attr_accessor :raw_sequence
  attr_accessor :protein_translation # used only for nucleotides
  attr_accessor :nucleotide_rf #used only for nucleotides

  def initialize
    @hsp_list = []
    @raw_sequence = nil
    @protein_translation = nil
    @nucleotide_rf = nil
  end

  def print
    puts "#{@object_type} sequence: #{@definition} "
    puts "Lengths xml #{@xml_length} fasta #{@fasta_length} hit #{@alignment.hit_seq.length}"
    puts "Accession = #{@accession_no}"
    puts "Species = #{@species}"
    puts "Raw_sequence = #{@raw_sequence.insert(@hit_from-1,'#').insert(@hit_to+1,'#')}"
    puts "Hit seq =      #{alignment.hit_seq}"
    puts "Query seq =    #{alignment.query_seq}"
    puts "----------------------"
  end

  def protein_translation

    if @type == :protein
      return raw_sequence
    else 
      return @protein_translation
    end
  end

  ##
  # Gets gene by accession number from a givem database
  # Params:
  # +accno+: accession number as String
  # +db+: database as String
  # Output:
  # String with the nucleotide sequence corresponding to the accno
  def get_sequence_by_accession_no(accno, db)

    uri = "http://www.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=#{db}&retmax=1&usehistory=y&term=#{accno}/"
    #puts uri
    result = Net::HTTP.get(URI.parse(uri))

    result2 = result
    queryKey = result2.scan(/<\bQueryKey\b>([\w\W\d]+)<\/\bQueryKey\b>/)[0][0]
    webEnv = result.scan(/<\bWebEnv\b>([\w\W\d]+)<\/\bWebEnv\b>/)[0][0]

    uri = "http://www.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?rettype=fasta&retmode=text&retstart=0&retmax=1&db=#{db}&query_key=#{queryKey}&WebEnv=#{webEnv}"

    result = Net::HTTP.get(URI.parse(uri))

    #parse FASTA output
    rec=result
    nl = rec.index("\n")
    header = rec[0..nl-1]
    seq = rec[nl+1..-1]
    @raw_sequence = seq.gsub!(/\n/,'')
  end

  ##
  # Initializes the corresponding attribute of the sequence
  # with respect to the column name of the tabular blast output
  def init_tabular_attribute(column, value)
    case column
      when "sseqid"
        @definition = value    
      when "qseqid"
        @definition = value
      when "sacc"
        @accession_no = value
      when "slen"
        @xml_length = value.to_i  
    end
  end

end
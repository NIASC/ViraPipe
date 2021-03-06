#!/usr/bin/env bash

#See below to set yarn and executor memory options right
#http://stackoverflow.com/questions/38331502/spark-on-yarn-resource-manager-relation-between-yarn-containers-and-spark-execu
#example parameters (data must be in /data/input/example in compressed fastq format and /data/output directory must exist)
#./pipeline_cluster.sh /data/input /data/output example

CLASSPATH=viraseq-0.9-jar-with-dependencies.jar
INPUT_PATH=${1} #path to HDFS input directory
OUTPUT_PATH=${2} #path to HDFS output directory
PROJECT_NAME=${3} #Used for directory name suffix
REF_INDEX=/index #path to reference index file in local filesystem of every node
ASSEMBLER_THREADS=10
NORMALIZATION_KMER_LEN=20
NORMALIZATION_CUTOFF=16
TEMP_PATH=${OUTPUT_PATH}/temp  #path to temp directory in HDFS
LOCAL_TEMP_PATH=/temp #path to temp directory in local filesystem of every node
BLAST_TASK=megablast #other option is blastn which is default
BLAST_DATABASE=/database/blast #path to local fs
BLAST_HUMAN_DATABASE=/database/blast
BLAST_PARTITIONS=100 #repartition contigs to this amount (default is same as number of samples)
BLAST_THREADS=10
HMM_DB=/database/hmmer
#EX_MEM=${4}
#NUM_EX=5
#EX_CORES=${8}

#Decompress and interleave all data from HDFS path
spark-submit --master local[20] --conf spark.shuffle.service.enabled=true --executor-memory 10g --class fi.aalto.ngs.metagenomics.DecompressInterleave ${CLASSPATH} -in ${INPUT_PATH} -temp ${TEMP_PATH} -out ${OUTPUT_PATH}/${PROJECT_NAME}_interleaved -remtemp

#Align and filter unmapped reads from interleaved reads diretory
spark-submit --master local[5] --conf spark.shuffle.service.enabled=true --executor-memory 40g --class fi.aalto.ngs.metagenomics.AlignInterleaved ${CLASSPATH} -in ${OUTPUT_PATH}/${PROJECT_NAME}_interleaved -out ${OUTPUT_PATH}/${PROJECT_NAME}_aligned -ref ${REF_INDEX}

#Normalize unmapped reads
spark-submit --master local[20] --conf spark.shuffle.service.enabled=true --executor-memory 10g --class fi.aalto.ngs.metagenomics.NormalizeRDD ${CLASSPATH} -in ${OUTPUT_PATH}/${PROJECT_NAME}_aligned -out ${OUTPUT_PATH}/${PROJECT_NAME}_normalized -k ${NORMALIZATION_KMER_LEN} -C ${NORMALIZATION_CUTOFF}

#Group output by samples
spark-submit --master local[20] --conf spark.shuffle.service.enabled=true --executor-memory 10g --class fi.aalto.ngs.metagenomics.FastqGroupper ${CLASSPATH} -in ${OUTPUT_PATH}/${PROJECT_NAME}_normalized -out ${OUTPUT_PATH}/${PROJECT_NAME}_groupped

#Assembly
spark-submit --master local[10] --conf spark.shuffle.service.enabled=true --executor-memory 20g --class fi.aalto.ngs.metagenomics.Assemble ${CLASSPATH} -in ${OUTPUT_PATH}/${PROJECT_NAME}_groupped -out ${OUTPUT_PATH}/${PROJECT_NAME}_assembled -localdir ${LOCAL_TEMP_PATH} -merge -t ${ASSEMBLER_THREADS}

#rename assembled contigs uniquely
spark-submit --master local[20] --conf spark.shuffle.service.enabled=true --executor-memory 10g --class fi.aalto.ngs.metagenomics.RenameContigsUniq ${CLASSPATH} -in ${OUTPUT_PATH}/${PROJECT_NAME}_assembled -out ${OUTPUT_PATH}/${PROJECT_NAME}_contigs -fa fa -partitions ${BLAST_PARTITIONS}

#Blast against human db and filter out human matches
spark-submit --master local[10] --conf spark.shuffle.service.enabled=true --executor-memory 20g --class fi.aalto.ngs.metagenomics.BlastNFilter ${CLASSPATH} -in ${OUTPUT_PATH}/${PROJECT_NAME}_contigs -out ${OUTPUT_PATH}/${PROJECT_NAME}_blast_nonhuman -db ${BLAST_HUMAN_DATABASE} -task megablast -outfmt 6 -threshold 70 -num_threads ${BLAST_THREADS}
#Blast non human contigs per file in parallel
spark-submit --master local[10] --conf spark.shuffle.service.enabled=true --executor-memory 20g --class fi.aalto.ngs.metagenomics.BlastN ${CLASSPATH} -in ${OUTPUT_PATH}/${PROJECT_NAME}_blast_nonhuman -out ${OUTPUT_PATH}/${PROJECT_NAME}_blast_final -db ${BLAST_DATABASE} -outfmt 6 -num_threads ${BLAST_THREADS}
#HMMSearch non human contigs per file in parallel
spark-submit --master local[20] --conf spark.shuffle.service.enabled=true --executor-memory 10g --class se.ki.ngs.metagenomics.sparkncbiblast.hmm.HMMSearch ${CLASSPATH} --inputDir ${OUTPUT_PATH}/${PROJECT_NAME}_blast_nonhuman -outputDir ${OUTPUT_PATH}/${PROJECT_NAME}_hmm --tempDir ${LOCAL_TEMP_PATH} --db ${HMM_DB} --minlength 60

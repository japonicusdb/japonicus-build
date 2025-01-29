#!/bin/bash -

set -eu
set -o pipefail

version=$1
dump_dir=$2

container_dir=.

(cd pombase-website; git pull)
(cd pombase-chado; git pull)
(cd pombase-chado-json; git pull)
(cd pombase-python-web; git pull)
(cd allele_qc; git pull)
(cd japonicus-build; git pull)
(cd japonicus-config; git pull)
(cd curation; git pull)

(cd pombase-website; cp src/japonicus/index.html src/)
(cd pombase-website/src/assets
 ln -sf japonicus-logo.png logo.png
 ln -sf japonicus-logo-small.png logo-small.png
 ln -sf japonicus-logo-tiny.png logo-tiny.png)

cp japonicus-build/setup_jbrowse2_in_container.sh $container_dir/container_scripts/

rsync -aL --delete-after --exclude '*~' pombase-chado/etc/docker-conf/ $container_dir/conf/

rsync -acvPHS --delete-after $dump_dir/web-json $container_dir/
rsync -acvPHS --delete-after $dump_dir/misc $container_dir/
rsync -acvPHS --delete-after $dump_dir/gff $container_dir/
rsync -acvPHS --delete-after $dump_dir/fasta/chromosomes/ $container_dir/chromosome_fasta/

cp $dump_dir/api_maps.sqlite3.zst $container_dir/

mkdir -p $container_dir/feature_sequences
rsync -acvPHS --delete-after $dump_dir/fasta/feature_sequences/peptide.fa.gz $container_dir/feature_sequences/peptide.fa.gz

pombase-chado/etc/create_jbrowse_track_list.pl \
   $container_dir/japonicus-config/trackListTemplate.json \
   $container_dir/japonicus-config/jbrowse_track_metadata.csv \
   $container_dir/trackList.json $container_dir/jbrowse_track_metadata.csv \
   $container_dir/minimal_jbrowse_track_list.json

echo building container ...
docker build -f conf/Dockerfile-main --build-arg database_name=japonicusdb --build-arg target=prod -t=japonicus/web:$version-prod .

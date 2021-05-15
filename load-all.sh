#!/bin/bash -

date

set -eu
set -o pipefail

HOST="$1"
DATE="$2"
USER="$3"
PASSWORD="$4"
PREV_VERSION="$5"
CURRENT_VERSION=`echo $PREV_VERSION | perl -ne 'if (/^v?(\d+)$/) { print "v" . ($1+1) . "\n"; } else { print "vUNKNOWN" }'`
PREV_DATE="$6"

die() {
  echo $1 1>&2
  exit 1
}

JBASE_HOME=`pwd`

JAPONICUS_BUILD=$JBASE_HOME/japonicus-build
JAPONICUS_CURATION=$JBASE_HOME/japonicus-curation
JAPONICUS_CONFIG=$JBASE_HOME/japonicus-config

POMCUR=/var/pomcur
SOURCES=$POMCUR/sources
JAPONICUS_SOURCES=$POMCUR/japonicus_sources

LOAD_CONFIG=$JAPONICUS_CONFIG/load-japonicus-chado.yaml
MAIN_CONFIG=$JAPONICUS_CONFIG/japonicus_site_config.json

LOG_DIR=$JBASE_HOME/logs

POMBASE_CHADO=$JBASE_HOME/pombase-chado
POMBASE_LEGACY=$JBASE_HOME/pombase-legacy

(cd chobo/; git pull) || die "Failed to update Chobo"

(cd pombase-chado; git pull) || die "Failed to update pombase-chado"
(cd pombase-legacy; git pull) || die "Failed to update pombase-legacy"

(cd pombase-website; git pull) || die "Failed to update pombase-website"

(cd $JAPONICUS_BUILD; git pull) || die "can't update japonicus-build"
(cd $JAPONICUS_CURATION; git pull) || die "can't update japonicus-curation"
(cd $JAPONICUS_CONFIG; git pull) || die "can't update japonicus-config"


(cd pombase-legacy
 export PATH=JBASE_HOME/chobo/script/:/usr/local/owltools-v0.3.0-74-gee0f8bbd/OWLTools-Runner/bin/:$PATH
 export CHADO_CLOSURE_TOOL=$JBASE_HOME/pombase-chado/script/relation-graph-chado-closure.pl
 export PERL5LIB=$POMBASE_CHADO/lib:$JBASE_HOME/chobo/lib/
 time nice -19 $JAPONICUS_BUILD/make-db $JBASE_HOME $DATE "$HOST" $USER $PASSWORD) || die "make-db failed"


DB_DATE_VERSION=$DATE
BASE_DB=jbase-base-$DB_DATE_VERSION
DB=jbase-build-$DB_DATE_VERSION

createdb -T $BASE_DB $DB


export PERL5LIB=$POMBASE_CHADO/lib:$POMBASE_LEGACY/lib

echo $PERL5LIB

echo initialising Chado with CVs and cvterms 
$JBASE_HOME/pombase-chado/script/pombase-admin.pl $LOAD_CONFIG chado-init \
  "$HOST" $DB $USER $PASSWORD || exit 1


echo loading organisms
$JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG organisms \
    "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CONFIG/japonicus_organism_config.tsv

#echo loading PB refs
#$JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG references-file \
#    "$HOST" $DB $USER $PASSWORD < $JBASE_HOME/svn-supporting-files/PB_references.txt


## echo loading human genes
## $JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
##     --organism-taxonid=9606 --uniquename-column=1 --name-column=2 --feature-type=gene \
##     --product-column=3 \
##     --ignore-lines-matching="^hgnc_id.symbol" --ignore-short-lines \
##     "$HOST" $DB $USER $PASSWORD < $SOURCES/hgnc_complete_set.txt


## echo loading protein coding genes from SGD data file
## $JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
##     --organism-taxonid=4932 --uniquename-column=5 --name-column=6 \
##     --product-column=4 \
##     --column-filter="1=ORF,blocked_reading_frame,blocked reading frame" --feature-type=gene \
##     --transcript-so-name=transcript \
##     --feature-prop-from-column=sgd_identifier:3 \
##     "$HOST" $DB $USER $PASSWORD < $SOURCES/sgd_yeastmine_genes.tsv

## for so_type in ncRNA snoRNA
## do
##   echo loading $so_type genes from SGD data file
##   $JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
##       --organism-taxonid=4932 --uniquename-column=5 --name-column=6 \
##       --column-filter="1=${so_type} gene" --feature-type=gene \
##       "$HOST" $DB $USER $PASSWORD < $SOURCES/sgd_yeastmine_genes.tsv
## done
## 


echo loading pombe genes

$JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
    --organism-taxonid=4896 --uniquename-column=1 --name-column=3 --feature-type=gene \
    --product-column=5 --ignore-short-lines \
    "$HOST" $DB $USER $PASSWORD < /var/www/pombase/dumps/latest_build/misc/gene_IDs_names_products.tsv



cd $LOG_DIR
log_file=log.`date +'%Y-%m-%d-%H-%M-%S'`
$POMBASE_LEGACY/script/load-chado.pl --taxonid=4897 \
  --gene-ex-qualifiers $JAPONICUS_CONFIG/gene_ex_qualifiers \
  $LOAD_CONFIG \
  "$HOST" $DB $USER $PASSWORD $JBASE_HOME/japonicus-curation/contigs/*.contig 2>&1 | tee $log_file || exit 1


$POMBASE_LEGACY/etc/process-log.pl $log_file



$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG generic-property \
    --property-name="uniprot_identifier" --organism-taxonid=4897 \
    --feature-uniquename-column=1 --property-column=2 \
    "$HOST" $DB $USER $PASSWORD < $JBASE_HOME/japonicus-curation/systematic_id_uniprot_mapping.tsv


evidence_summary () {
  DB=$1
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'evidence') group by value order by count(feature_cvtermprop_id)" | cat
}

assigned_by_summary () {
  DB=$1
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'assigned_by') group by value order by count(feature_cvtermprop_id);" | cat
}

refresh_views () {
  for view in \
    pombase_annotated_gene_features_per_publication \
    pombase_feature_cvterm_with_ext_parents \
    pombase_feature_cvterm_no_ext_terms \
    pombase_feature_cvterm_ext_resolved_terms \
    pombase_genotypes_alleles_genes_mrna \
    pombase_extension_rels_and_values \
    pombase_genes_annotations_dates \
    pombase_annotation_summary \
    pombase_publication_curation_summary
  do
    psql $DB -c "REFRESH MATERIALIZED VIEW $view;"
  done
}

echo annotation evidence counts before loading
evidence_summary $DB


CURRENT_GOA_GAF=$JBASE_HOME/sources/goa_gene_association_japonicus.tsv.gz

gzip -d < $CURRENT_GOA_GAF | rg '\ttaxon:(4897|402676)\t' |
    $POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG gaf \
       --taxon-filter=4897 \
       --use-only-first-with-id --term-id-filter-filename=$JAPONICUS_CONFIG/goa-load-fixes/filtered_GO_IDs \
       --with-filter-filename=$JAPONICUS_CONFIG/goa-load-fixes/filtered_mappings \
       --assigned-by-filter=EnsemblFungi,GOC,RNAcentral,InterPro,UniProtKB,UniProt "$HOST" $DB $USER $PASSWORD


echo load Compara orthologs

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --publication=null --organism_1_taxonid=4897 --organism_2_taxonid=4896 \
  --swap-direction \
  "$HOST" $DB $USER $PASSWORD < $JBASE_HOME/japonicus-curation/manual_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.manual_orthologs


refresh_views

# run this before loading the Canto data because the Canto loader creates
# reciprocals automatically
# See: https://github.com/pombase/pombase-chado/issues/723
# and: https://github.com/pombase/pombase-chado/issues/788
$JBASE_HOME/pombase-chado/script/pombase-process.pl \
    $LOAD_CONFIG add-reciprocal-ipi-annotations \
    --organism-taxonid=4897 "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.add_reciprocal_ipi_annotations


PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'
refresh_views

echo update out of date allele names
$POMBASE_CHADO/script/pombase-process.pl $LOAD_CONFIG update-allele-names "$HOST" $DB $USER $PASSWORD

echo change UniProtKB IDs in "with" feature_cvterprop rows to PomBase IDs
$POMBASE_CHADO/script/pombase-process.pl $LOAD_CONFIG uniprot-ids-to-local "$HOST" $DB $USER $PASSWORD

echo do GO term re-mapping
$POMBASE_CHADO/script/pombase-process.pl $LOAD_CONFIG change-terms \
  --exclude-by-fc-prop="canto_session" \
  --mapping-file=$SOURCES/pombe-embl/chado_load_mappings/GO_mapping_to_specific_terms.txt \
  "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.go-term-mapping


CURATION_TOOL_DATA=$POMCUR/backups/japonicus-current.json

echo
echo load Canto data
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG canto-json \
   --organism-taxonid=4897 --db-prefix=JaponicusDB \
   "$HOST" $DB $USER $PASSWORD < $CURATION_TOOL_DATA 2>&1 | tee $LOG_DIR/$log_file.curation_tool_data

echo annotation count after loading curation tool data:
evidence_summary $DB


echo
echo counts of assigned_by before filtering:
assigned_by_summary $DB


echo
echo filtering redundant annotations - `date`
$JBASE_HOME/pombase-chado/script/pombase-process.pl $LOAD_CONFIG go-filter "$HOST" $DB $USER $PASSWORD
echo done filtering - `date`



echo
echo counts of assigned_by after filtering:
assigned_by_summary $DB

echo
echo annotation count after filtering redundant GO annotations
evidence_summary $DB

echo
echo query PubMed for publication details, then store
$POMBASE_CHADO/script/pubmed_util.pl $LOAD_CONFIG \
  "$HOST" $DB $USER $PASSWORD --add-missing-fields 2>&1 | tee $LOG_DIR/$log_file.pubmed_query

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'
refresh_views

echo
echo running consistency checks
if $POMBASE_CHADO/script/check-chado.pl $LOAD_CONFIG $MAIN_CONFIG "$HOST" $DB $USER $PASSWORD > $LOG_DIR/$log_file.chado_checks 2>&1
then
    CHADO_CHECKS_STATUS=passed
else
    CHADO_CHECKS_STATUS=failed
fi


DUMPS_DIR=$JBASE_HOME/outputs
BUILDS_DIR=$DUMPS_DIR/builds
CURRENT_BUILD_DIR=$BUILDS_DIR/$DB

mkdir -p $CURRENT_BUILD_DIR
mkdir -p $CURRENT_BUILD_DIR/logs
mkdir -p $CURRENT_BUILD_DIR/exports

(
echo starting gaf export at `date`
$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG gaf \
     --organism-taxon-id=4897 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.gaf.gz
echo starting go-physical-interactions export at `date`

psql $DB -t --no-align -c "
SELECT uniquename FROM pub WHERE uniquename LIKE 'PMID:%'
   AND pub_id IN (SELECT pub_id FROM feature_cvterm UNION SELECT pub_id FROM feature_relationship_pub)
 ORDER BY substring(uniquename FROM 'PMID:(\d+)')::integer;" > $CURRENT_BUILD_DIR/publications_with_annotations.txt

) > $LOG_DIR/$log_file.export_warnings 2>&1



cp $LOG_DIR/$log_file.* $CURRENT_BUILD_DIR/logs/

refresh_views

(
echo extension relation counts:
psql $DB -c "select count(id), name, base_cv_name from (select p.cvterm_id::text || '_cvterm' as id,
  substring(type.name from 'annotation_extension_relation-(.*)') as name, base_cv_name
  from pombase_feature_cvterm_ext_resolved_terms fc
       join cvtermprop p on p.cvterm_id = fc.cvterm_id
       join cvterm type on p.type_id = type.cvterm_id
  where type.name like 'annotation_ex%'
UNION all select r.cvterm_relationship_id::text ||
  '_cvterm_rel' as id, t.name as name, base_cv_name from cvterm_relationship r join cvterm t on t.cvterm_id = r.type_id join pombase_feature_cvterm_ext_resolved_terms fc on r.subject_id = fc.cvterm_id  where
  t.name <> 'is_a' and r.subject_id in (select cvterm_id from cvterm, cv
  where cvterm.cv_id = cv.cv_id and cv.name = 'PomBase annotation extension terms'))
  as sub group by base_cv_name, name order by base_cv_name, name;
"

echo
echo number of annotations using extensions by cv:

psql $DB -c "select count(feature_cvterm_id), base_cv_name from pombase_feature_cvterm_with_ext_parents group by base_cv_name order by count;"
) > $CURRENT_BUILD_DIR/logs/$log_file.extension_relation_counts

(
echo counts of qualifiers grouped by CV name
psql $DB -c "select count(fc.feature_cvterm_id), value, base_cv_name from feature_cvtermprop p, pombase_feature_cvterm_ext_resolved_terms fc, cvterm t where type_id = (select cvterm_id from cvterm where name = 'qualifier' and cv_id = (select cv_id from cv where name = 'feature_cvtermprop_type')) and p.feature_cvterm_id = fc.feature_cvterm_id and fc.cvterm_id = t.cvterm_id group by value, base_cv_name order by count desc;"
) > $CURRENT_BUILD_DIR/logs/$log_file.qualifier_counts_by_cv

(
echo all protein family term and annotated genes
psql $DB -c "select t.name, db.name || ':' || x.accession as termid, array_to_string(array_agg(f.uniquename), ',') as gene_uniquenames from feature f join feature_cvterm fc on fc.feature_id = f.feature_id join cvterm t on t.cvterm_id = fc.cvterm_id join dbxref x on x.dbxref_id = t.dbxref_id join db on x.db_id = db.db_id join cv on t.cv_id = cv.cv_id where cv.name = 'PomBase family or domain' group by t.name, termid order by t.name, termid;"
) > $CURRENT_BUILD_DIR/logs/$log_file.protein_family_term_annotation

(
echo 'Alleles with type "other"'
psql $DB -F ',' -A -c "select f.name, f.uniquename, (select value from featureprop p where
p.feature_id = f.feature_id and p.type_id in (select cvterm_id from cvterm
where name = 'description')) as description, ARRAY(select value from featureprop p where
p.feature_id = f.feature_id and p.type_id in (select cvterm_id from cvterm
where name = 'canto_session')) as session from feature f where type_id in (select
cvterm_id from cvterm where name = 'allele') and feature_id in (select
feature_id from featureprop p where p.type_id in (select cvterm_id from cvterm
where name = 'allele_type') and p.value = 'other');"
) > $CURRENT_BUILD_DIR/logs/$log_file.alleles_of_type_other

(
echo counts of all annotation by type:
psql $DB -c "select count(distinct fc_id), cv_name from (select distinct
fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
and cv.name <> 'PomBase annotation extension terms' UNION select distinct
fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
= t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
and parent_term.cv_id = parent_cv.cv_id and term_cv.name = 'PomBase annotation extension terms' and rel.type_id = rel_type.cvterm_id and rel_type.name =
'is_a') as sub group by cv_name order by count;"
echo

echo annotation counts by evidence code and cv type, sorted by cv name:
psql $DB -c "with sub as (select distinct
 fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
 and cv.name <> 'PomBase annotation extension terms' UNION select distinct
 fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
 = t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
 and parent_term.cv_id = parent_cv.cv_id and term_cv.name =
 'PomBase annotation extension terms' and rel.type_id =
 rel_type.cvterm_id and rel_type.name = 'is_a')
 select p.value as ev_code, cv_name, count(fc_id) from sub join
 feature_cvtermprop p on sub.fc_id = p.feature_cvterm_id where type_id
 = (select cvterm_id from cvterm t join cv on t.cv_id = cv.cv_id where
 cv.name = 'feature_cvtermprop_type' and t.name = 'evidence') group by
 p.value, cv_name order by cv_name;"
echo

echo annotation counts by evidence code and cv type, sorted by count:
psql $DB -c "with sub as (select distinct
 fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
 and cv.name <> 'PomBase annotation extension terms' UNION select distinct
 fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
 = t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
 and parent_term.cv_id = parent_cv.cv_id and term_cv.name =
 'PomBase annotation extension terms' and rel.type_id =
 rel_type.cvterm_id and rel_type.name = 'is_a')
 select p.value as ev_code, cv_name, count(fc_id) from sub join
 feature_cvtermprop p on sub.fc_id = p.feature_cvterm_id where type_id
 = (select cvterm_id from cvterm t join cv on t.cv_id = cv.cv_id where
 cv.name = 'feature_cvtermprop_type' and t.name = 'evidence') group by
 p.value, cv_name order by count;"
echo

echo annotation counts by evidence code and cv type, sorted by cv evidence code:
psql $DB -c "with sub as (select distinct
 fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
 and cv.name <> 'PomBase annotation extension terms' UNION select distinct
 fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
 = t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
 and parent_term.cv_id = parent_cv.cv_id and term_cv.name =
 'PomBase annotation extension terms' and rel.type_id =
 rel_type.cvterm_id and rel_type.name = 'is_a')
 select p.value as ev_code, cv_name, count(fc_id) from sub join
 feature_cvtermprop p on sub.fc_id = p.feature_cvterm_id where type_id
 = (select cvterm_id from cvterm t join cv on t.cv_id = cv.cv_id where
 cv.name = 'feature_cvtermprop_type' and t.name = 'evidence') group by
 p.value, cv_name order by p.value;"
echo

echo total:
psql $DB -c "select count(distinct fc_id) from (select distinct
fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
and cv.name <> 'PomBase annotation extension terms' UNION select distinct
fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
= t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
and parent_term.cv_id = parent_cv.cv_id and term_cv.name = 'PomBase annotation extension terms' and rel.type_id = rel_type.cvterm_id and rel_type.name =
'is_a') as sub;"

echo
echo counts of annotation from Canto, by type:
sub_query="(select
 distinct fc.feature_cvterm_id as fc_id, cv.name as cv_name from
 cvterm t, feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and
 cv.cv_id = t.cv_id and cv.name <> 'PomBase annotation extension
 terms' and fc.feature_cvterm_id in (select feature_cvterm_id from
 feature_cvtermprop where type_id in (select cvterm_id from cvterm
 where name = 'canto_session')) UNION select distinct fc.feature_cvterm_id
 as fc_id, parent_cv.name as cv_name from cvterm t, feature_cvterm fc,
 cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and
 term_cv.cv_id = t.cv_id and t.cvterm_id = subject_id and
 parent_term.cvterm_id = object_id and parent_term.cv_id =
 parent_cv.cv_id and term_cv.name = 'PomBase annotation extension
 terms' and rel.type_id = rel_type.cvterm_id and rel_type.name =
 'is_a' and fc.feature_cvterm_id in (select feature_cvterm_id from
 feature_cvtermprop where type_id in (select cvterm_id from cvterm
 where name = 'canto_session'))) as sub"
psql $DB -c "select count(distinct fc_id), cv_name from $sub_query group by cv_name order by count;"
psql $DB -c "select count(distinct fc_id) as total from $sub_query;"

 ) > $CURRENT_BUILD_DIR/logs/$log_file.annotation_counts_by_cv

refresh_views


$POMCUR/bin/pombase-chado-json -c $MAIN_CONFIG \
   --doc-config-file $JBASE_HOME/pombase-website/src/app/config/doc-config.json \
   -p "postgres://$USER:$PASSWORD@localhost/$DB" \
   -d $CURRENT_BUILD_DIR/ --go-eco-mapping=$SOURCES/gaf-eco-mapping.txt \
   -i $JAPONICUS_SOURCES/japonicus_domain_results.json \
   --pfam-data-file $JAPONICUS_CURATION/pfam_japonicus_protein_data.json \
   2>&1 | tee $LOG_DIR/$log_file.web-json-write

find $CURRENT_BUILD_DIR/fasta -name '*.fa' | xargs gzip -9f

cp $LOG_DIR/$log_file.web-json-write $CURRENT_BUILD_DIR/logs/

DB_BASE_NAME=`echo $DB | sed 's/-v[0-9]$//'`


cp $LOG_DIR/*.txt $CURRENT_BUILD_DIR/logs/

psql $DB -c 'grant select on all tables in schema public to public;'

DUMP_FILE=$CURRENT_BUILD_DIR/$DB.chado_dump.gz

echo dumping to $DUMP_FILE
pg_dump $DB | gzip -9 > $DUMP_FILE

rm -f $DUMPS_DIR/latest_build
ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/latest_build

(cd $JBASE_HOME/container_build
 (cd japonicus-config && git pull)
 cp -f japonicus-config/japonicus_site_config.json main_config.json
 nice -10 $JAPONICUS_BUILD/build_container.sh $DB_DATE_VERSION $DUMPS_DIR/latest_build)

IMAGE_NAME=japonicus/web:$DB_DATE_VERSION-prod

docker service update --image=$IMAGE_NAME japonicus-dev

if [ $CHADO_CHECKS_STATUS=passed ]
then
    rm -f $DUMPS_DIR/nightly_update
    ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/nightly_update
fi

date

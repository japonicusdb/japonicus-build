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

DATE_VERSION=$DATE

JBASE_HOME=`pwd`

JAPONICUS_BUILD=$JBASE_HOME/japonicus-build
JAPONICUS_CURATION=$JBASE_HOME/japonicus-curation
JAPONICUS_CONFIG=$JBASE_HOME/japonicus-config

POMCUR=/var/pomcur
SOURCES=$POMCUR/sources
JAPONICUS_SOURCES=$POMCUR/japonicus_sources

WWW_DIR=/var/www/pombase

POMBASE_NIGHTLY=$WWW_DIR/dumps

LOAD_CONFIG=$JAPONICUS_CONFIG/load-japonicus-chado.yaml
MAIN_CONFIG=$JAPONICUS_CONFIG/japonicus_site_config.json

LOG_DIR=$JBASE_HOME/logs

POMBASE_CHADO=$JBASE_HOME/pombase-chado
POMBASE_LEGACY=$JBASE_HOME/pombase-legacy


(cd chobo/; git pull) || die "Failed to update Chobo"

(cd pombase-chado; git pull) || die "Failed to update pombase-chado"
(cd pombase-legacy; git pull) || die "Failed to update pombase-legacy"

(cd pombase-website; git pull) || die "Failed to update pombase-website"

(cd $JAPONICUS_BUILD; git pull) || die "can't update $JAPONICUS_BUILD"
(cd $JAPONICUS_CURATION; git pull) || die "can't update $JAPONICUS_CURATION"
(cd $JAPONICUS_CONFIG; git pull) || die "can't update $JAPONICUS_CONFIG"


(cd pombase-legacy
 export PATH=JBASE_HOME/chobo/script/:/usr/local/owltools-v0.3.0-74-gee0f8bbd/OWLTools-Runner/bin/:$PATH
 export CHADO_CLOSURE_TOOL=$JBASE_HOME/pombase-chado/script/relation-graph-chado-closure.pl
 export PERL5LIB=$POMBASE_CHADO/lib:$JBASE_HOME/chobo/lib/
 time nice -19 $JAPONICUS_BUILD/make-db $JBASE_HOME $DATE "$HOST" $USER $PASSWORD) || die "make-db failed"


BASE_DB=japonicusdb-base-$DATE_VERSION
DB=japonicusdb-build-$DATE_VERSION

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

echo loading GO refs parsed from go-site/metadata/gorefs/
$JBASE_HOME/pombase-chado/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml references-file \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/go_references.txt


echo loading human genes
$JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
    --organism-taxonid=9606 --uniquename-column=1 --name-column=2 --feature-type=gene \
    --transcript-so-name=transcript --product-column=3 \
    --ignore-lines-matching="^hgnc_id.symbol" --ignore-short-lines \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/hgnc_complete_set.txt


echo loading protein coding genes from SGD data file
$JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
    --organism-taxonid=4932 --uniquename-column=5 --name-column=6 \
    --product-column=4 \
    --column-filter="1=ORF,blocked_reading_frame,blocked reading frame" --feature-type=gene \
    --transcript-so-name=transcript \
    --feature-prop-from-column=sgd_identifier:3 \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/sgd_yeastmine_genes.tsv

for so_type in ncRNA snoRNA
do
  echo loading $so_type genes from SGD data file
  $JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
      --organism-taxonid=4932 --uniquename-column=5 --name-column=6 \
      --transcript-so-name=$so_type \
      --column-filter="1=${so_type} gene" --feature-type=gene \
      "$HOST" $DB $USER $PASSWORD < $SOURCES/sgd_yeastmine_genes.tsv
done



echo loading pombe genes

$JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
    --organism-taxonid=4896 --uniquename-column=1 --name-column=3 --feature-type=gene \
    --product-column=5 --ignore-short-lines \
    --transcript-so-name=mRNA --column-filter="7=protein coding gene" \
    "$HOST" $DB $USER $PASSWORD < $POMBASE_NIGHTLY/latest_build/misc/gene_IDs_names_products.tsv

for so_type in ncRNA tRNA snoRNA rRNA snRNA
do
  $JBASE_HOME/pombase-chado/script/pombase-import.pl $LOAD_CONFIG features \
      --organism-taxonid=4896 --uniquename-column=1 --name-column=3 \
      --product-column=5 --ignore-short-lines \
      --transcript-so-name=$so_type \
      --column-filter="7=${so_type} gene" --feature-type=gene \
     "$HOST" $DB $USER $PASSWORD < $POMBASE_NIGHTLY/latest_build/misc/gene_IDs_names_products.tsv
done


cd $LOG_DIR
log_file=log.`date +'%Y-%m-%d-%H-%M-%S'`
$POMBASE_LEGACY/script/load-chado.pl --taxonid=4897 \
  --gene-ex-qualifiers $JAPONICUS_CONFIG/gene_ex_qualifiers \
  $LOAD_CONFIG $DATE_VERSION \
  "$HOST" $DB $USER $PASSWORD $JAPONICUS_CURATION/contigs/*.contig 2>&1 | tee $log_file || exit 1


$POMBASE_LEGACY/etc/process-log.pl $log_file

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'


echo loading names_and_products.tsv
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG names-and-products \
    --dest-organism-taxonid=4897 \
    "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/names_and_products.tsv


echo loading systematic_id_uniprot_mapping.tsv
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG generic-property \
    --property-name="uniprot_identifier" --organism-taxonid=4897 \
    --feature-uniquename-column=1 --property-column=2 \
    "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/systematic_id_uniprot_mapping.tsv

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG generic-property \
    --property-name="uniprot_identifier" --organism-taxonid=4896 \
    --feature-uniquename-column=1 --property-column=2 \
    "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/pombe_systematic_id_uniprot_mapping.tsv


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


pg_dump $DB | gzip -9 > /tmp/japonicus-chado-10-pre-goa.dump.gz


CURRENT_GOA_GAF=$SOURCES/gene_association.goa_uniprot.gz
GOA_POMBE_AND_JAPONICUS="$SOURCES/gene_association.goa_uniprot.pombe+japonicus.gz"
GOA_VERSION=`cat $GOA_POMBE_AND_JAPONICUS.uniprot_version`

$POMBASE_CHADO/script/pombase-admin.pl $LOAD_CONFIG add-chado-prop \
  "$HOST" $DB $USER $PASSWORD "UniProt-GOA_version" $GOA_VERSION

echo reading $GOA_POMBE_AND_JAPONICUS
gzip -d < $GOA_POMBE_AND_JAPONICUS | perl -ne 'print if /\ttaxon:(4897|402676)\t/' |
    $POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG gaf \
       --taxon-filter=4897 --use-only-first-with-id \
       --term-id-filter-filename=<(cat $SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs $JAPONICUS_CURATION/japonicusdb_only_filtered_GO_IDs) \
       --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings \
       --assigned-by-filter=GOC,RNAcentral,InterPro,UniProtKB,UniProt "$HOST" $DB $USER $PASSWORD \
       2>&1 | tee $LOG_DIR/$log_file.goa_gene_association_japonicus

echo load PANTHER annotation
gzip -d < $CURRENT_GOA_GAF | perl -ne 'print if /\ttaxon:(4897|402676)\t/' |
    $POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG gaf \
       --taxon-filter=4897 \
       --with-prefix-filter="PANTHER:" \
       --term-id-filter-filename=<(cat $SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs $JAPONICUS_CURATION/japonicusdb_only_filtered_GO_IDs) \
       --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings \
       --assigned-by-filter=GO_Central "$HOST" $DB $USER $PASSWORD \
       2>&1 | tee $LOG_DIR/$log_file.goa_gene_association_panther_japonicus


pg_dump $DB | gzip -9 > /tmp/japonicus-chado-20-after-goa.dump.gz


echo annotation count after GAF loading:
evidence_summary $DB


echo load manual annotation
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG gaf \
    --taxon-filter=4897 \
    --assigned-by-filter=EnsemblFungi,GOC,RNAcentral,InterPro,UniProtKB,UniProt,JaponicusDB \
    "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/Gene_ontology/manual_go_annotation.gaf \
    2>&1 | tee $LOG_DIR/$log_file.manual_go_annotation


pg_dump $DB | gzip -9 > /tmp/japonicus-chado-30-after-manual-annotation.dump.gz


echo load Compara pombe orthologs

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --publication=PMID:26896847 --organism_1_taxonid=4897 --organism_2_taxonid=4896 \
  "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/compara_pombe_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.compara_pombe_orthologs

echo load Rhind pombe orthologs

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --publication=PMID:21511999 --organism_1_taxonid=4897 --organism_2_taxonid=4896 \
  "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/rhind_pombe_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.rhind_pombe_orthologs

echo load manual pombe orthologs

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --publication=null --organism_1_taxonid=4897 --organism_2_taxonid=4896 \
  "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/manual_pombe_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.manual_pombe_orthologs


echo load cerevisiae orthologs

# load via pombe orthologs first
echo "  via pombe"
$JAPONICUS_BUILD/project-pombe-orthologs.pl \
    <(curl -s --http1.1 https://curation.pombase.org/dumps/latest_build/exports/pombe-cerevisiae-orthologs-with-systematic-ids.txt.gz | gzip -d) \
    <($POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG simple-orthologs --organism-taxon-id=4897 --other-organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD) |
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --publication=PMID:29761456 --organism_1_taxonid=4897 --organism_2_taxonid=4932 \
  "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.cerevisiae_orthologs_via_pombe

$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG simple-orthologs \
  --organism-taxon-id=4897 --other-organism-taxon-id=4932 \
  "$HOST" $DB $USER $PASSWORD > /tmp/japonicus_cerevisiae_orthologs_via_pombe.tsv

echo "  from Compara"
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --publication=PMID:26896847 --organism_1_taxonid=4897 --organism_2_taxonid=4932 \
  "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/cerevisiae_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.compara_cerevisiae_orthologs


echo load human orthologs

$JAPONICUS_BUILD/project-pombe-orthologs.pl \
    <(curl -s --http1.1 https://curation.pombase.org/dumps/latest_build/exports/pombe-human-orthologs-with-systematic-ids.txt.gz | gzip -d) \
    <($POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG simple-orthologs --organism-taxon-id=4897 --other-organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD) |
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --publication=PMID:29761456 --organism_1_taxonid=4897 --organism_2_taxonid=9606 \
  "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.human_orthologs


echo transfer names and products from pombe to japonicus

$JBASE_HOME/pombase-chado/script/pombase-process.pl \
  $LOAD_CONFIG transfer-names-and-products \
  --source-organism-taxonid=4896 --dest-organism-taxonid=4897 \
  "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.transfer_names_and_products


pg_dump $DB | gzip -9 > /tmp/japonicus-chado-40-after-orthologs-and-names.dump.gz



PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'

echo transfer GO annotation from pombe

#curl -s --http1.1 https://curation.pombase.org/dumps/latest_build/pombase-latest.gaf.gz |
#    gzip -d |

gzip -d < $WWW_DIR/dumps/latest_build/pombase-latest.gaf.gz |
    $POMBASE_CHADO/script/pombase-process.pl $LOAD_CONFIG transfer-gaf-annotations \
       --source-organism-taxonid=4896 --dest-organism-taxonid=4897 \
       --evidence-codes-to-ignore=ND --terms-to-ignore="GO:0005515" \
       "$HOST" $DB $USER $PASSWORD |
    $POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG gaf \
       --term-id-filter-filename=$JAPONICUS_CURATION/japonicusdb_only_filtered_GO_IDs \
       --taxon-filter=4897 "$HOST" $DB $USER $PASSWORD \
       2>&1 | tee $LOG_DIR/$log_file.transfer_pombe_go_annotation


pg_dump $DB | gzip -9 > /tmp/japonicus-chado-50-after-pombe-go-annotation.gz


echo load PDBe IDs

perl -ne '
    ($id, $pdb_id, $taxon_id) = split /\t/;
    print "$id\t$pdb_id\n" if $taxon_id == 4897;
  ' < $SOURCES/pombe-embl/external_data/protein_structure/systematic_id_to_pdbe_mapping_japonicus.tsv |
    sort | uniq |
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml generic-property \
    --property-name="pdb_identifier" --organism-taxonid=4897 \
    --feature-uniquename-column=1 --property-column=2 \
    "$HOST" $DB $USER $PASSWORD


refresh_views

# run this before loading the Canto data because the Canto loader creates
# reciprocals automatically
# See: https://github.com/pombase/pombase-chado/issues/723
# and: https://github.com/pombase/pombase-chado/issues/788
$JBASE_HOME/pombase-chado/script/pombase-process.pl \
    $LOAD_CONFIG add-reciprocal-ipi-annotations \
    --organism-taxonid=4897 "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.add_reciprocal_ipi_annotations

pg_dump $DB | gzip -9 > /tmp/japonicus-chado-60-after-reciprocal-ipi-annotations.gz


PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'
refresh_views

echo update out of date allele names
$POMBASE_CHADO/script/pombase-process.pl $LOAD_CONFIG update-allele-names "$HOST" $DB $USER $PASSWORD


echo do GO term re-mapping
$POMBASE_CHADO/script/pombase-process.pl $LOAD_CONFIG change-terms \
  --exclude-by-fc-prop="canto_session" \
  --mapping-file=$SOURCES/pombe-embl/chado_load_mappings/GO_mapping_to_specific_terms.txt \
  "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.go-term-mapping


CURATION_TOOL_DATA=$POMCUR/backups/japonicus-current.json

echo
echo load Canto data
$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG canto-json \
   --organism-taxonid=4897 --db-prefix=JaponicusDB --all-curation-is-community \
   "$HOST" $DB $USER $PASSWORD < $CURATION_TOOL_DATA 2>&1 | tee $LOG_DIR/$log_file.curation_tool_data

echo annotation count after loading curation tool data:
evidence_summary $DB

pg_dump $DB | gzip -9 > /tmp/japonicus-chado-70-after-canto-data.gz


echo
echo counts of assigned_by before filtering:
assigned_by_summary $DB

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'

echo
echo filtering redundant annotations - `date`
$JBASE_HOME/pombase-chado/script/pombase-process.pl $LOAD_CONFIG go-filter "$HOST" $DB $USER $PASSWORD
echo done GO filtering - `date`


echo
echo filtering redundant annotations - `date`
$JBASE_HOME/pombase-chado/script/pombase-process.pl $LOAD_CONFIG go-filter-with-not "$HOST" $DB $USER $PASSWORD
echo done filtering using NOT annotations - `date`


pg_dump $DB | gzip -9 > /tmp/japonicus-chado-80-go-filtering.gz

echo
echo counts of assigned_by after filtering:
assigned_by_summary $DB

echo
echo annotation count after filtering redundant GO annotations
evidence_summary $DB

echo
echo query PubMed for publication details, then store
$POMBASE_CHADO/script/pubmed_util.pl $LOAD_CONFIG \
  "$HOST" $DB $USER $PASSWORD --add-missing-fields \
  --organism-taxonid=4897 2>&1 | tee $LOG_DIR/$log_file.pubmed_query


echo
echo loading finished


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

echo Chado checks $CHADO_CHECKS_STATUS


DUMPS_DIR=$WWW_DIR/japonicus_nightly
BUILDS_DIR=$DUMPS_DIR/builds
CURRENT_BUILD_DIR=$BUILDS_DIR/$DB

mkdir -p $CURRENT_BUILD_DIR
mkdir -p $CURRENT_BUILD_DIR/logs
mkdir -p $CURRENT_BUILD_DIR/exports


(

echo starting orthologs export at `date`
$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG orthologs --organism-taxon-id=4897 --other-organism-taxon-id=4896 --other-organism-field-name=uniquename --other-organism-field-name=uniquename --sensible-ortholog-direction "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.japonicus-pombe-orthologs.txt.gz
$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG orthologs --organism-taxon-id=4897 --other-organism-taxon-id=9606 --sensible-ortholog-direction "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.japonicus-human-orthologs.txt.gz
$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG orthologs --organism-taxon-id=4897 --other-organism-taxon-id=4932 --other-organism-field-name=uniquename --sensible-ortholog-direction "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.japonicus-cerevisiae-orthologs.txt.gz

echo starting gaf export at `date`
$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG gaf --organism-taxon-id=4897 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.gaf.gz

echo starting phaf export at `date`
$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG phaf --organism-taxon-id=4897 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.phaf.gz

echo starting modifications export at `date`
$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG modifications --organism-taxon-id=4897 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.modifications.gz

psql $DB -t --no-align -c "
SELECT uniquename FROM pub WHERE uniquename LIKE 'PMID:%'
   AND pub_id IN (SELECT pub_id FROM feature_cvterm UNION SELECT pub_id FROM feature_relationship_pub)
 ORDER BY substring(uniquename FROM 'PMID:(\d+)')::integer;" > $CURRENT_BUILD_DIR/publications_with_annotations.txt

) > $LOG_DIR/$log_file.export_warnings 2>&1



cp $LOG_DIR/$log_file.* $CURRENT_BUILD_DIR/logs/


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
 parent_cv.cv_id and term_cv.name = 'PomBase annotation extension terms'
 and rel.type_id = rel_type.cvterm_id and rel_type.name =
 'is_a' and fc.feature_cvterm_id in (select feature_cvterm_id from
 feature_cvtermprop where type_id in (select cvterm_id from cvterm
 where name = 'canto_session'))) as sub"
psql $DB -c "select count(distinct fc_id), cv_name from $sub_query group by cv_name order by count;"
psql $DB -c "select count(distinct fc_id) as total from $sub_query;"

 ) > $CURRENT_BUILD_DIR/logs/$log_file.annotation_counts_by_cv


echo creating files for the website:
$POMCUR/bin/pombase-chado-json -c $MAIN_CONFIG \
   --doc-config-file $JBASE_HOME/pombase-website/src/app/config/doc-config.json \
   -p "postgres://$USER:$PASSWORD@localhost/$DB" \
   -d $CURRENT_BUILD_DIR/ --go-eco-mapping=$SOURCES/gaf-eco-mapping.txt \
   -i $JAPONICUS_SOURCES/japonicus_domain_results.json \
   --pfam-data-file $JAPONICUS_CURATION/pfam_japonicus_protein_data.json \
   --pdb-data-file $SOURCES/pombe-embl/external_data/protein_structure/systematic_id_to_pdbe_mapping_japonicus.tsv \
   2>&1 | tee $LOG_DIR/$log_file.web-json-write

find $CURRENT_BUILD_DIR/fasta -name '*.fa' | xargs gzip -9f

cp $LOG_DIR/$log_file.web-json-write $CURRENT_BUILD_DIR/logs/

DB_BASE_NAME=`echo $DB | sed 's/-v[0-9]$//'`

zstd -9q --rm $CURRENT_BUILD_DIR/api_maps.sqlite3


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
 nice -10 $JAPONICUS_BUILD/build_container.sh $DATE_VERSION $DUMPS_DIR/latest_build)

IMAGE_NAME=japonicus/web:$DATE_VERSION-prod

# temporarily add another replica so so have no downtime when we update
docker service update --replicas 2 japonicus-1
sleep 60
docker service update --update-delay 0s --image=$IMAGE_NAME japonicus-1
sleep 60
docker service update --replicas 1 japonicus-1

#if [ $CHADO_CHECKS_STATUS=passed ]
#then
    rm -f $DUMPS_DIR/nightly_update
    ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/nightly_update

    WWW_JAPONICUS_DIR=/var/www/www-japonicusdb
    WWW_DATA_DIR=$WWW_JAPONICUS_DIR/data

    cp $JAPONICUS_CURATION/systematic_id_uniprot_mapping.tsv $WWW_DATA_DIR/names_and_identifiers/JaponicusDB2UniProt.tsv

    cp $CURRENT_BUILD_DIR/misc/gene_IDs_names.tsv          $WWW_DATA_DIR/names_and_identifiers/
    cp $CURRENT_BUILD_DIR/misc/gene_IDs_names_products.tsv $WWW_DATA_DIR/names_and_identifiers/
    cp $CURRENT_BUILD_DIR/misc/sysID2product.tsv           $WWW_DATA_DIR/names_and_identifiers/
    cp $CURRENT_BUILD_DIR/misc/sysID2product.rna.tsv       $WWW_DATA_DIR/names_and_identifiers/

    cp $CURRENT_BUILD_DIR/misc/Complex_annotation.tsv      $WWW_DATA_DIR/annotations/Gene_ontology/GO_complexes/Complex_annotation.tsv

    gzip -9 < $CURRENT_BUILD_DIR/misc/gene_product_annotation_data_taxonid_4897.tsv > $WWW_DATA_DIR/annotations/Gene_ontology/japonicusdb.gpad.gz
    gzip -9 < $CURRENT_BUILD_DIR/misc/gene_product_information_taxonid_4897.tsv     > $WWW_DATA_DIR/annotations/Gene_ontology/japonicusdb.gpi.gz

    gzip -9 < $CURRENT_BUILD_DIR/misc/go_style_gaf.tsv                              > $WWW_DATA_DIR/annotations/Gene_ontology/gene_association_2-2.japonicusdb.gz
    gzip -9 < $CURRENT_BUILD_DIR/misc/pombase_style_gaf.tsv                         > $WWW_DATA_DIR/annotations/Gene_ontology/gene_association_2-1.japonicusdb.gz

    cp $CURRENT_BUILD_DIR/misc/transmembrane_domain_coords_and_seqs.tsv  $WWW_DATA_DIR/Protein_data/
    cp $CURRENT_BUILD_DIR/misc/aa_composition.tsv                        $WWW_DATA_DIR/Protein_data/
    cp $CURRENT_BUILD_DIR/misc/PeptideStats.tsv                          $WWW_DATA_DIR/Protein_data/
    cp $CURRENT_BUILD_DIR/misc/ProteinFeatures.tsv                       $WWW_DATA_DIR/Protein_data/Protein_Features.tsv

    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/cds+introns+utrs.fa.gz   $WWW_DATA_DIR/genome_sequence_and_features/feature_sequences/cds+introns+utrs.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/cds+introns.fa.gz        $WWW_DATA_DIR/genome_sequence_and_features/feature_sequences/cds+introns.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/cds.fa.gz                $WWW_DATA_DIR/genome_sequence_and_features/feature_sequences/cds.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/introns_within_cds.fa.gz $WWW_DATA_DIR/genome_sequence_and_features/feature_sequences/introns_within_cds.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/five_prime_utrs.fa.gz    $WWW_DATA_DIR/genome_sequence_and_features/feature_sequences/UTR/5UTR.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/three_prime_utrs.fa.gz   $WWW_DATA_DIR/genome_sequence_and_features/feature_sequences/UTR/3UTR.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/peptide.fa.gz            $WWW_DATA_DIR/genome_sequence_and_features/feature_sequences/peptide.fa.gz

    cp $CURRENT_BUILD_DIR/fasta/chromosomes/*.gz      $WWW_DATA_DIR/genome_sequence_and_features/genome_sequence/

    (cd $CURRENT_BUILD_DIR/gff
    for f in *.gff3
    do
        gzip -9 < $f > $WWW_DATA_DIR/genome_sequence_and_features/gff3/$f.gz
    done)

    cp $CURRENT_BUILD_DIR/$DB.japonicus-human-orthologs.txt.gz       $WWW_DATA_DIR/orthologs/japonicus-human-orthologs.txt.gz
    cp $CURRENT_BUILD_DIR/$DB.japonicus-pombe-orthologs.txt.gz       $WWW_DATA_DIR/orthologs/japonicus-pombe-orthologs.txt.gz
    cp $CURRENT_BUILD_DIR/$DB.japonicus-cerevisiae-orthologs.txt.gz  $WWW_DATA_DIR/orthologs/japonicus-cerevisiae-orthologs.txt.gz
    cp $CURRENT_BUILD_DIR/$DB.modifications.gz             $WWW_DATA_DIR/annotations/modifications/japonicusdb-chado.modifications.gz
    cp $CURRENT_BUILD_DIR/$DB.phaf.gz                      $WWW_DATA_DIR/annotations/Phenotype_annotations/phenotype_annotations.japonicusdb.phaf.gz

#fi

cat > $POMCUR/apps/japonicus/canto_chado.yaml <<EOF

Model::ChadoModel:
  connect_info:
    - "dbi:Pg:dbname=$DB;host=localhost"
    - japonicus
    - japonicus
  schema_class: Canto::ChadoDB

EOF

echo finished building: $DB

date

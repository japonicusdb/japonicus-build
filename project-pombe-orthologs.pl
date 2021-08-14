#!/usr/bin/env perl

# read a PomBase ortholog file for cerevisiae or human and the
# pombe-japonicus orthologs file, then output a cerevisiae-japonicus
# or human-japonicus ortholog file for loading with pombase-import.pl

use strict;
use warnings;
use Carp;


my %pombe_other_map = ();


open my $pombe_other_file, '<', $ARGV[0] or die;

while (<$pombe_other_file>) {
  chomp $_;
  my ($pombe_gene, $other_genes) = split /\t/, $_;

  for my $other_gene (split /\|/, $other_genes) {
    if ($other_gene ne 'NONE') {
      push @{$pombe_other_map{$pombe_gene}}, $other_gene;
    }
  }
}


open my $japonicus_pombe_file, '<', $ARGV[1] or die;

while (<$japonicus_pombe_file>) {
  chomp $_;
  my ($japonicus_gene, $pombe_gene) = split /\t/, $_;

  my $other_genes = $pombe_other_map{$pombe_gene};

  if ($other_genes) {
    for my $other_gene (@$other_genes) {
      print "$japonicus_gene\t$other_gene\n";
    }
  }
}

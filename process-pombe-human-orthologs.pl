#!/usr/bin/env perl

# read the PomBase pombe-human ortholog file and the japonicus-pombe
# orthologs file, then output a human-japonicus file for loading with
# pombase-import.pl

use strict;
use warnings;
use Carp;


my %pombe_human_map = ();


open my $pombe_human_file, '<', $ARGV[0] or die;

while (<$pombe_human_file>) {
  chomp $_;
  my ($pombe_gene, $human_genes) = split /\t/, $_;

  for my $human_gene (split /\|/, $human_genes) {
    if ($human_gene ne 'NONE') {
      push @{$pombe_human_map{$pombe_gene}}, $human_gene;
    }
  }
}


open my $japonicus_pombe_file, '<', $ARGV[1] or die;

while (<$japonicus_pombe_file>) {
  chomp $_;
  my ($japonicus_gene, $pombe_gene) = split /\t/, $_;

  my $human_genes = $pombe_human_map{$pombe_gene};

  if ($human_genes) {
    for my $human_gene (@$human_genes) {
      print "$japonicus_gene\t$human_gene\n";
    }
  }
}

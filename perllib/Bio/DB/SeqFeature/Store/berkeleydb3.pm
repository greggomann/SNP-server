package Bio::DB::SeqFeature::Store::berkeleydb3;

# $Id: berkeleydb3.pm 15987 2009-08-18 21:08:55Z lstein $
# faster implementation of berkeleydb

=head1 NAME

Bio::DB::SeqFeature::Store::berkeleydb3 -- Storage and retrieval of sequence
annotation data in Berkeleydb files

=head1 SYNOPSIS

  # Create a feature database from scratch
  $db     = Bio::DB::SeqFeature::Store->new( -adaptor => 'berkeleydb',
                                             -dsn     => '/var/databases/fly4.3',
                                             -create  => 1);

  # get a feature from somewhere
  my $feature = Bio::SeqFeature::Generic->new(...);

  # store it
  $db->store($feature) or die "Couldn't store!";

=head1 DESCRIPTION

This is a faster version of the berkeleydb storage adaptor for
Bio::DB::SeqFeature::Store. It is used automatically when you create a
new database with the original berkeleydb adaptor. When opening a
database created under the original adaptor, the old code is used for
backward compatibility.

Please see L<Bio::DB::SeqFeature::Store::berkeleydb3> for full usage
instructions.

=head1 BUGS

This is an early version, so there are certainly some bugs. Please
use the BioPerl bug tracking system to report bugs.

=head1 SEE ALSO

L<bioperl>,
L<Bio::DB::SeqFeature>,
L<Bio::DB::SeqFeature::Store>,
L<Bio::DB::SeqFeature::GFF3Loader>,
L<Bio::DB::SeqFeature::Segment>,
L<Bio::DB::SeqFeature::Store::memory>,
L<Bio::DB::SeqFeature::Store::DBI::mysql>,

=head1 AUTHOR

Lincoln Stein E<lt>lincoln.stein@gmail.comE<gt>.

Copyright (c) 2009 Ontario Institute for Cancer Research

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


use strict;
use base 'Bio::DB::SeqFeature::Store::berkeleydb';
use DB_File;
use Fcntl qw(O_RDWR O_CREAT :flock);
use Bio::DB::GFF::Util::Rearrange 'rearrange';

# can't have more sequence ids than this
use constant MAX_SEQUENCES => 1_000_000_000;
use constant BINSIZE       => 10_000;
use constant MININT        => -999_999_999_999;
use constant MAXINT        => 999_999_999_999;

sub version { return 3.0 }

sub open_index_dbs {
    my $self = shift;
    my ($flags,$create) = @_;

    # Create the main index databases; these are DB_BTREE implementations with duplicates allowed.
    $DB_BTREE->{flags}  = R_DUP;

    my $string_cmp          = DB_File::BTREEINFO->new;
    $string_cmp->{flags}    = R_DUP;
    $string_cmp->{compare}  = sub { lc $_[0] cmp lc $_[1] };

    my $numeric_cmp         = DB_File::BTREEINFO->new;
    $numeric_cmp->{flags}   = R_DUP;
    $numeric_cmp->{compare} = sub { $_[0] <=> $_[1] };

    for my $idx ($self->_index_files) {
	my $path    = $self->_qualify("$idx.idx");
	my %db;
	my $dbtype  = $idx eq 'locations' ? $numeric_cmp
                     :$idx eq 'types'     ? $numeric_cmp
                     :$idx eq 'seqids'    ? $DB_HASH
                     :$idx eq 'typeids'   ? $DB_HASH
                     :$string_cmp;

	tie(%db,'DB_File',$path,$flags,0666,$dbtype)
	    or $self->throw("Couldn't tie $path: $!");
	%db = () if $create;
	$self->index_db($idx=>\%db);
    }

}

sub seqid_db  { shift->index_db('seqids')    }
sub typeid_db { shift->index_db('typeids') }

sub _delete_databases {
    my $self = shift;
    $self->SUPER::_delete_databases;
}

# given a seqid (name), return its denormalized numeric representation
sub seqid_id {
    my $self   = shift;
    my $seqid  = shift;
    my $db     = $self->seqid_db;
    return $db->{lc $seqid};
}

sub add_seqid {
    my $self  = shift;
    my $seqid = shift;

    my $db    = $self->seqid_db;
    my $key   = lc $seqid;
    $db->{$key} = ++$db->{'.nextid'} unless exists $db->{$key};
    die "Maximum number of sequence ids exceeded. This module can handle up to ",
        MAX_SEQUENCES," unique ids" if $db->{$key} > MAX_SEQUENCES;
    return $db->{$key};
}

# given a seqid (name), return its denormalized numeric representation
sub type_id {
    my $self   = shift;
    my $typeid  = shift;
    my $db     = $self->typeid_db;
    return $db->{$typeid};
}

sub add_typeid {
    my $self  = shift;
    my $typeid = shift;

    my $db      = $self->typeid_db;
    my $key     = lc $typeid;
    $db->{$key} = ++$db->{'.nextid'} unless exists $db->{$key};
    return $db->{$key};
}

sub _index_files {
    return shift->SUPER::_index_files,'seqids','typeids';
}

sub _update_indexes {
    my $self = shift;
    my $obj  = shift;
    defined (my $id   = $obj->primary_id) or return;
    $self->SUPER::_update_indexes($obj);
    $self->_update_seqid_index($obj,$id);
}

sub _update_seqid_index {
    my $self = shift;
    my ($obj,$id,$delete) = @_;
    my $seq_name = $obj->seq_id;
    $self->add_seqid(lc $seq_name);
}

sub _update_type_index {
  my $self = shift;
  my ($obj,$id,$delete) = @_;
  my $db = $self->index_db('types')
    or $self->throw("Couldn't find 'types' index file");

  my $key         = $self->_obj_to_type($obj);
  my $typeid      = $self->add_typeid($key);
  $self->update_or_delete($delete,$db,$typeid,$id);
}

sub _obj_to_type {
    my $self = shift;
    my $obj  = shift;
    my $tag         = $obj->primary_tag;
    my $source_tag  = $obj->source_tag || '';
    return unless defined $tag;

    $tag           .= ":$source_tag";
    return lc $tag;
}

sub types {
    my $self = shift;
    eval "require Bio::DB::GFF::Typename" 
	unless Bio::DB::GFF::Typename->can('new');
    my $db   = $self->typeid_db;
    return grep {!/^\./} map {Bio::DB::GFF::Typename->new($_)} keys %$db;
}

# return a hash of typeids that match a human-readable type
sub _matching_types {
    my $self  = shift;
    my $types = shift;
    my @types = ref $types eq 'ARRAY' ?  @$types : $types;
    my $db   = $self->typeid_db;

    my %result;
    my @all_types;

    for my $type (@types) {
	my ($primary_tag,$source_tag);
	if (ref $type && $type->isa('Bio::DB::GFF::Typename')) {
	    $primary_tag = $type->method;
	    $source_tag  = $type->source;
	} else {
	    ($primary_tag,$source_tag) = split ':',$type,2;
	}
	if (defined $source_tag) {
	    my $id = $db->{lc "$primary_tag:$source_tag"};
	    $result{$id}++ if defined $id;
	} else {
	    @all_types  = $self->types unless @all_types;
	    $result{$db->{$_}}++ foreach grep {/^$primary_tag:/} @all_types;
	}
    }
    return \%result;
}

sub _update_location_index {
  my $self = shift;
  my ($obj,$id,$delete) = @_;

  my $db = $self->index_db('locations')
    or $self->throw("Couldn't find 'locations' index file");

  my $seq_id      = $obj->seq_id || '';
  my $start       = $obj->start  || '';
  my $end         = $obj->end    || '';
  my $strand      = $obj->strand;
  my $bin_min     = int $start/BINSIZE;
  my $bin_max     = int $end/BINSIZE;

  my $typeid      = $self->add_typeid($self->_obj_to_type($obj));
  my $seq_no      = $self->add_seqid($seq_id);

  for (my $bin = $bin_min; $bin <= $bin_max; $bin++ ) {
    my $key = $seq_no * MAX_SEQUENCES + $bin;
    $self->update_or_delete($delete,$db,$key,pack("i5",$id,$start,$end,$strand,$typeid));
  }

}

sub _features {
  my $self = shift;
  my ($seq_id,$start,$end,$strand,
      $name,$class,$allow_aliases,
      $types,
      $attributes,
      $range_type,
      $iterator
     ) = rearrange([['SEQID','SEQ_ID','REF'],'START',['STOP','END'],'STRAND',
		    'NAME','CLASS','ALIASES',
		    ['TYPES','TYPE','PRIMARY_TAG'],
		    ['ATTRIBUTES','ATTRIBUTE'],
		    'RANGE_TYPE',
		    'ITERATOR',
		   ],@_);

  my (@from,@where,@args,@group);
  $range_type ||= 'overlaps';

  my @result;
  unless (defined $name or defined $seq_id or defined $types or defined $attributes) {
    @result = grep {!/^\./} keys %{$self->db};
  }

  my %found = ();
  my $result = 1;

  if (defined($name)) {
    # hacky backward compatibility workaround
    undef $class if $class && $class eq 'Sequence';
    $name     = "$class:$name" if defined $class && length $class > 0;
    $result &&= $self->filter_by_name($name,$allow_aliases,\%found);
  }

  if (defined $seq_id) { # location with or without types
      my $typelist = defined $types ? $self->_matching_types($types) : undef;
      $result &&= $self->filter_by_type_and_location($seq_id,$start,$end,$strand,$range_type,
						     $typelist, \%found);
  }

  elsif (defined $types) { # types without location
      $result &&= $self->filter_by_type($types,\%found);
  }

  if (defined $attributes) {
    $result &&= $self->filter_by_attribute($attributes,\%found);
  }

  push @result,keys %found if $result;
  return $iterator ? Bio::DB::SeqFeature::Store::berkeleydb::Iterator->new($self,\@result)
                   : map {$self->fetch($_)} @result;
}

sub filter_by_type_and_location {
  my $self = shift;
  my ($seq_id,$start,$end,$strand,$range_type,$typelist,$filter) = @_;
  $strand ||= 0;

  my $index    = $self->index_db('locations');
  my $db       = tied(%$index);

  my $binstart = defined $start ? int $start/BINSIZE : 0;
  my $binend   = defined $end   ? int $end/BINSIZE   : MAX_SEQUENCES-1;

  my %seenit;
  my @results;

  $start = MININT  if !defined $start;
  $end   = MAXINT  if !defined $end;

  my $seq_no = $self->seqid_id($seq_id);
  return unless defined $seq_no;

  if ($range_type eq 'overlaps' or $range_type eq 'contains') {
    my $keystart = $seq_no * MAX_SEQUENCES + $binstart;
    my $keystop  = $seq_no * MAX_SEQUENCES + $binend;
    my $value;

    for (my $status = $db->seq($keystart,$value,R_CURSOR);
	 $status == 0 && $keystart <= $keystop;
	 $status = $db->seq($keystart,$value,R_NEXT)) {
      my ($id,$fstart,$fend,$fstrand,$ftype) = unpack("i5",$value);
      next if $seenit{$id}++;
      next if $strand   && $fstrand != $strand;
      next if $typelist && !$typelist->{$ftype};
      if ($range_type eq 'overlaps') {
	next unless $fend >= $start && $fstart <= $end;
      }
      elsif ($range_type eq 'contains') {
	next unless $fstart >= $start && $fend <= $end;
      }
      next if %$filter && !$filter->{$id};  # don't bother
      push @results,$id;
    }
  }

  # for contained in, we look for features originating and terminating outside the specified range
  # this is incredibly inefficient, but fortunately the query is rare (?)
  elsif ($range_type eq 'contained_in') {
    my $keystart = $seq_no * MAX_SEQUENCES;
    my $keystop  = $seq_no * MAX_SEQUENCES + $binstart;
    my $value;

    # do the left part of the range
    for (my $status = $db->seq($keystart,$value,R_CURSOR);
	 $status == 0 && $keystart <= $keystop;
	 $status = $db->seq($keystart,$value,R_NEXT)) {
      my ($id,$fstart,$fend,$fstrand,$ftype) = unpack("i5",$value);
      next if $seenit{$id}++;
      next if $strand && $fstrand != $strand;
      next if $typelist && !$typelist->{$ftype};
      next unless $fstart <= $start && $fend >= $end;
      next if %$filter && !$filter->{$id};  # don't bother
      push @results,$id;
    }

    # do the right part of the range
    $keystart = $seq_no*MAX_SEQUENCES+$binend;
    for (my $status = $db->seq($keystart,$value,R_CURSOR);
	 $status == 0;
	 $status = $db->seq($keystart,$value,R_NEXT)) {
      my ($id,$fstart,$fend,$fstrand,$ftype) = unpack("i5",$value);
      next if $seenit{$id}++;
      next if $strand && $fstrand != $strand;
      next unless $fstart <= $start && $fend >= $end;
      next if $typelist && !$typelist->{$ftype};
      next if %$filter && !$filter->{$id};  # don't bother
      push @results,$id;
    }

  }

  $self->update_filter($filter,\@results);
}

1;


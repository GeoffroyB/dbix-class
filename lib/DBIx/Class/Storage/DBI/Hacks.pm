package DBIx::Class::Storage::DBI::Hacks;

#
# This module contains code that should never have seen the light of day,
# does not belong in the Storage, or is otherwise unfit for public
# display. The arrival of SQLA2 should immediatelyt oboslere 90% of this
#

use strict;
use warnings;

use base 'DBIx::Class::Storage';
use mro 'c3';

use Carp::Clan qw/^DBIx::Class/;

#
# This is the code producing joined subqueries like:
# SELECT me.*, other.* FROM ( SELECT me.* FROM ... ) JOIN other ON ... 
#
sub _adjust_select_args_for_complex_prefetch {
  my ($self, $from, $select, $where, $attrs) = @_;

  $self->throw_exception ('Nothing to prefetch... how did we get here?!')
    if not @{$attrs->{_prefetch_select}};

  $self->throw_exception ('Complex prefetches are not supported on resultsets with a custom from attribute')
    if (ref $from ne 'ARRAY' || ref $from->[0] ne 'HASH' || ref $from->[1] ne 'ARRAY');


  # generate inner/outer attribute lists, remove stuff that doesn't apply
  my $outer_attrs = { %$attrs };
  delete $outer_attrs->{$_} for qw/where bind rows offset group_by having/;

  my $inner_attrs = { %$attrs };
  delete $inner_attrs->{$_} for qw/for collapse _prefetch_select _collapse_order_by select as/;


  # bring over all non-collapse-induced order_by into the inner query (if any)
  # the outer one will have to keep them all
  delete $inner_attrs->{order_by};
  if (my $ord_cnt = @{$outer_attrs->{order_by}} - @{$outer_attrs->{_collapse_order_by}} ) {
    $inner_attrs->{order_by} = [
      @{$outer_attrs->{order_by}}[ 0 .. $ord_cnt - 1]
    ];
  }


  # generate the inner/outer select lists
  # for inside we consider only stuff *not* brought in by the prefetch
  # on the outside we substitute any function for its alias
  my $outer_select = [ @$select ];
  my $inner_select = [];
  for my $i (0 .. ( @$outer_select - @{$outer_attrs->{_prefetch_select}} - 1) ) {
    my $sel = $outer_select->[$i];

    if (ref $sel eq 'HASH' ) {
      $sel->{-as} ||= $attrs->{as}[$i];
      $outer_select->[$i] = join ('.', $attrs->{alias}, ($sel->{-as} || "inner_column_$i") );
    }

    push @$inner_select, $sel;
  }

  # normalize a copy of $from, so it will be easier to work with further
  # down (i.e. promote the initial hashref to an AoH)
  $from = [ @$from ];
  $from->[0] = [ $from->[0] ];
  my %original_join_info = map { $_->[0]{-alias} => $_->[0] } (@$from);


  # decide which parts of the join will remain in either part of
  # the outer/inner query

  # First we compose a list of which aliases are used in restrictions
  # (i.e. conditions/order/grouping/etc). Since we do not have
  # introspectable SQLA, we fall back to ugly scanning of raw SQL for
  # WHERE, and for pieces of ORDER BY in order to determine which aliases
  # need to appear in the resulting sql.
  # It may not be very efficient, but it's a reasonable stop-gap
  # Also unqualified column names will not be considered, but more often
  # than not this is actually ok
  #
  # In the same loop we enumerate part of the selection aliases, as
  # it requires the same sqla hack for the time being
  my ($restrict_aliases, $select_aliases, $prefetch_aliases);
  {
    # produce stuff unquoted, so it can be scanned
    my $sql_maker = $self->sql_maker;
    local $sql_maker->{quote_char};
    my $sep = $self->_sql_maker_opts->{name_sep} || '.';
    $sep = "\Q$sep\E";

    my $non_prefetch_select_sql = $sql_maker->_recurse_fields ($inner_select);
    my $prefetch_select_sql = $sql_maker->_recurse_fields ($outer_attrs->{_prefetch_select});
    my $where_sql = $sql_maker->where ($where);
    my $group_by_sql = $sql_maker->_order_by({
      map { $_ => $inner_attrs->{$_} } qw/group_by having/
    });
    my @non_prefetch_order_by_chunks = (map
      { ref $_ ? $_->[0] : $_ }
      $sql_maker->_order_by_chunks ($inner_attrs->{order_by})
    );


    for my $alias (keys %original_join_info) {
      my $seen_re = qr/\b $alias $sep/x;

      for my $piece ($where_sql, $group_by_sql, @non_prefetch_order_by_chunks ) {
        if ($piece =~ $seen_re) {
          $restrict_aliases->{$alias} = 1;
        }
      }

      if ($non_prefetch_select_sql =~ $seen_re) {
          $select_aliases->{$alias} = 1;
      }

      if ($prefetch_select_sql =~ $seen_re) {
          $prefetch_aliases->{$alias} = 1;
      }

    }
  }

  # Add any non-left joins to the restriction list (such joins are indeed restrictions)
  for my $j (values %original_join_info) {
    my $alias = $j->{-alias} or next;
    $restrict_aliases->{$alias} = 1 if (
      (not $j->{-join_type})
        or
      ($j->{-join_type} !~ /^left (?: \s+ outer)? $/xi)
    );
  }

  # mark all join parents as mentioned
  # (e.g.  join => { cds => 'tracks' } - tracks will need to bring cds too )
  for my $collection ($restrict_aliases, $select_aliases) {
    for my $alias (keys %$collection) {
      $collection->{$_} = 1
        for (@{ $original_join_info{$alias}{-join_path} || [] });
    }
  }

  # construct the inner $from for the subquery
  my %inner_joins = (map { %{$_ || {}} } ($restrict_aliases, $select_aliases) );
  my @inner_from;
  for my $j (@$from) {
    push @inner_from, $j if $inner_joins{$j->[0]{-alias}};
  }

  # if a multi-type join was needed in the subquery ("multi" is indicated by
  # presence in {collapse}) - add a group_by to simulate the collapse in the subq
  unless ($inner_attrs->{group_by}) {
    for my $alias (keys %inner_joins) {

      # the dot comes from some weirdness in collapse
      # remove after the rewrite
      if ($attrs->{collapse}{".$alias"}) {
        $inner_attrs->{group_by} ||= $inner_select;
        last;
      }
    }
  }

  # demote the inner_from head
  $inner_from[0] = $inner_from[0][0];

  # generate the subquery
  my $subq = $self->_select_args_to_query (
    \@inner_from,
    $inner_select,
    $where,
    $inner_attrs,
  );

  my $subq_joinspec = {
    -alias => $attrs->{alias},
    -source_handle => $inner_from[0]{-source_handle},
    $attrs->{alias} => $subq,
  };

  # Generate the outer from - this is relatively easy (really just replace
  # the join slot with the subquery), with a major caveat - we can not
  # join anything that is non-selecting (not part of the prefetch), but at
  # the same time is a multi-type relationship, as it will explode the result.
  #
  # There are two possibilities here
  # - either the join is non-restricting, in which case we simply throw it away
  # - it is part of the restrictions, in which case we need to collapse the outer
  #   result by tackling yet another group_by to the outside of the query

  # so first generate the outer_from, up to the substitution point
  my @outer_from;
  while (my $j = shift @$from) {
    if ($j->[0]{-alias} eq $attrs->{alias}) { # time to swap
      push @outer_from, [
        $subq_joinspec,
        @{$j}[1 .. $#$j],
      ];
      last; # we'll take care of what's left in $from below
    }
    else {
      push @outer_from, $j;
    }
  }

  # see what's left - throw away if not selecting/restricting
  # also throw in a group_by if restricting to guard against
  # cross-join explosions
  #
  while (my $j = shift @$from) {
    my $alias = $j->[0]{-alias};

    if ($select_aliases->{$alias} || $prefetch_aliases->{$alias}) {
      push @outer_from, $j;
    }
    elsif ($restrict_aliases->{$alias}) {
      push @outer_from, $j;

      # FIXME - this should be obviated by SQLA2, as I'll be able to 
      # have restrict_inner and restrict_outer... or something to that
      # effect... I think...

      # FIXME2 - I can't find a clean way to determine if a particular join
      # is a multi - instead I am just treating everything as a potential
      # explosive join (ribasushi)
      #
      # if (my $handle = $j->[0]{-source_handle}) {
      #   my $rsrc = $handle->resolve;
      #   ... need to bail out of the following if this is not a multi,
      #       as it will be much easier on the db ...

          $outer_attrs->{group_by} ||= $outer_select;
      # }
    }
  }

  # demote the outer_from head
  $outer_from[0] = $outer_from[0][0];

  # This is totally horrific - the $where ends up in both the inner and outer query
  # Unfortunately not much can be done until SQLA2 introspection arrives, and even
  # then if where conditions apply to the *right* side of the prefetch, you may have
  # to both filter the inner select (e.g. to apply a limit) and then have to re-filter
  # the outer select to exclude joins you didin't want in the first place
  #
  # OTOH it can be seen as a plus: <ash> (notes that this query would make a DBA cry ;)
  return (\@outer_from, $outer_select, $where, $outer_attrs);
}

sub _resolve_ident_sources {
  my ($self, $ident) = @_;

  my $alias2source = {};
  my $rs_alias;

  # the reason this is so contrived is that $ident may be a {from}
  # structure, specifying multiple tables to join
  if ( Scalar::Util::blessed($ident) && $ident->isa("DBIx::Class::ResultSource") ) {
    # this is compat mode for insert/update/delete which do not deal with aliases
    $alias2source->{me} = $ident;
    $rs_alias = 'me';
  }
  elsif (ref $ident eq 'ARRAY') {

    for (@$ident) {
      my $tabinfo;
      if (ref $_ eq 'HASH') {
        $tabinfo = $_;
        $rs_alias = $tabinfo->{-alias};
      }
      if (ref $_ eq 'ARRAY' and ref $_->[0] eq 'HASH') {
        $tabinfo = $_->[0];
      }

      $alias2source->{$tabinfo->{-alias}} = $tabinfo->{-source_handle}->resolve
        if ($tabinfo->{-source_handle});
    }
  }

  return ($alias2source, $rs_alias);
}

# Takes $ident, \@column_names
#
# returns { $column_name => \%column_info, ... }
# also note: this adds -result_source => $rsrc to the column info
#
# usage:
#   my $col_sources = $self->_resolve_column_info($ident, @column_names);
sub _resolve_column_info {
  my ($self, $ident, $colnames) = @_;
  my ($alias2src, $root_alias) = $self->_resolve_ident_sources($ident);

  my $sep = $self->_sql_maker_opts->{name_sep} || '.';
  $sep = "\Q$sep\E";

  my (%return, %seen_cols);

  # compile a global list of column names, to be able to properly
  # disambiguate unqualified column names (if at all possible)
  for my $alias (keys %$alias2src) {
    my $rsrc = $alias2src->{$alias};
    for my $colname ($rsrc->columns) {
      push @{$seen_cols{$colname}}, $alias;
    }
  }

  COLUMN:
  foreach my $col (@$colnames) {
    my ($alias, $colname) = $col =~ m/^ (?: ([^$sep]+) $sep)? (.+) $/x;

    unless ($alias) {
      # see if the column was seen exactly once (so we know which rsrc it came from)
      if ($seen_cols{$colname} and @{$seen_cols{$colname}} == 1) {
        $alias = $seen_cols{$colname}[0];
      }
      else {
        next COLUMN;
      }
    }

    my $rsrc = $alias2src->{$alias};
    $return{$col} = $rsrc && {
      %{$rsrc->column_info($colname)},
      -result_source => $rsrc,
      -source_alias => $alias,
    };
  }

  return \%return;
}

1;

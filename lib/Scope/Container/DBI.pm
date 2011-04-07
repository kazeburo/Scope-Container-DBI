package Scope::Container::DBI;

use strict;
use warnings;
use Scope::Container;
use Log::Minimal;
use List::Util qw/shuffle/;
use Data::Dumper;
use Carp;
use DBI;

our $VERSION = '0.02';
our $DBI_CLASS = 'DBI';

sub connect {
    my $class = shift;

    if ( @_ && (ref $_[0] || '' eq 'ARRAY') ) {
        my @dsn = @_;
        my $dbi;
        my $dsn_key = _build_dsn_key(@dsn);
        my $dbh = _lookup_cache($dsn_key);
        return $dbh if $dbh;

        for my $s_dsn ( shuffle(@dsn) ) {
            eval {
                ($dbh, $dbi) = $class->connect(@$s_dsn);
            };
            infof("Connection failed: " . $@) if $@;
            last if ( $dbh );
        }

        if ( $dbh ) {
            _save_cache($dsn_key, $dbi);
            return wantarray ? ( $dbh, $dbi) : $dbh;
        }
        
        croak("couldn't connect all DB, " .
            join(",", map { $_->[0] } @dsn));
    }

    my @dsn = @_;
    my $dsn_key = _build_dsn_key(\@dsn);     
    my $cached_dbh = _lookup_cache($dsn_key);
    return $cached_dbh if $cached_dbh;

    my ($dsn, $user, $pass, $attr) = @dsn;
    $attr->{AutoInactiveDestroy} = 1;

    my $dbh = do {
        if ($INC{'Apache/DBI.pm'} && $ENV{MOD_PERL}) {
            local $DBI::connect_via = 'connect'; # Disable Apache::DBI.
            $DBI_CLASS->connect( $dsn, $user, $pass, $attr );
        } else {
            $DBI_CLASS->connect( $dsn, $user, $pass, $attr );
        }
    };
    croak($DBI::errstr) if !$dbh;

    my $dbi = {
        dbh => $dbh,
        pid => $$,
    };
    $dbi->{tid} = threads->tid if $INC{'threads.pm'};

    _save_cache($dsn_key, $dbi);
    return wantarray ? ( $dbh, $dbi ) : $dbh;
}


sub _build_dsn_key {
    my @dsn = @_;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Indent = 0;
    my $key = Data::Dumper::Dumper(\@dsn);
    "sc:dbix:".$key;
}

sub _lookup_cache {
    my $key = shift;
    return unless in_scope_container();
    my $dbi = scope_container($key);
    return if !$dbi;

    my $dbh = $dbi->{dbh};
    if ( defined $dbi->{tid} && $dbi->{tid} != threads->tid ) {
        return;
    }
    if ( $dbi->{pid} != $$ ) {
        $dbh->STORE(InactiveDestroy => 1);
        return;
    }
    return $dbh if $dbh->FETCH('Active') && $dbh->ping;
    return;
}

sub _save_cache {
    my $key = shift;
    return unless in_scope_container();
    scope_container($key, shift);
}

1;
__END__

=head1 NAME

Scope::Container::DBI - DB connection manager with Scope::Container

=head1 SYNOPSIS

  use Scope::Container::DBI;
  use Scope::Container;

  FOO: {
      my $contaier = start_scope_container();

      # first connect
      my $dbh = Scope::Container::DBI->connect(
          'dbi:mysql:mydb;host=myhost', 'myuser', 'mypasswd',
          { RaiseError => 1, mysql_connect_timeout => 4, mysql_enable_utf8 => 1 }
      );

      # same dsn, user/pass, and attributes, reuse connection
      my $dbh2 = Scope::Container::DBI->connect(
          'dbi:mysql:mydb;host=myhost', 'myuser', 'mypasswd',
          { RaiseError => 1, mysql_connect_timeout => 4, mysql_enable_utf8 => 1 }
      );

      #disconnect
  }

  BAR: {
      my $contaier = start_scope_container();

      # connect randomly
      my $dbh = Scope::Container::DBI->connect(
          ['dbi:mysql:mydb;host=myslave01', 'myuser', 'mypasswd', {..}],
          ['dbi:mysql:mydb;host=myslave02', 'myuser', 'mypasswd', {..}],
          ['dbi:mysql:mydb;host=myslave03', 'myuser', 'mypasswd', {..}],
      );

      # reuse randomly connected 
      my $dbh2 = Scope::Container::DBI->connect(
          ['dbi:mysql:mydb;host=myslave01', 'myuser', 'mypasswd', {..}],
          ['dbi:mysql:mydb;host=myslave02', 'myuser', 'mypasswd', {..}],
          ['dbi:mysql:mydb;host=myslave03', 'myuser', 'mypasswd', {..}],
      );

  }

=head1 DESCRIPTION

Scope::Container::DBI is DB connection manager that uses Scope::Container. 
You can control DB connection within any scope.

=head1 METHOD

=over 4

=item $dbh = Scope::Container::DBI->connect();

connect to databases and cache connections.

  $dbh = Scope::Container::DBI->connect($dsn,$user,$password,$attr);

You can give multiple dsn with arrayref, Scope::Container::DBI chooses database randomly.
 
  $dbh = Scope::Container::DBI->connect(
      [$dsn,$user,$password,$attr],
      [$dsn,$user,$password,$attr],
      [$dsn,$user,$password,$attr]
  );

=back

=head1 NOTE

=over 4

=item Fork/Thread Safety

Scope::Container::DBI checks pid or thread id when reuses database connections. If pid is different, sets InactiveDestroy to true and don't reuse it.

=item Callbacks

Scope::Container::DBI doesn't have callback function, but you can set callbacks after connect with DBI's Callbacks function.

  my $dbh = Scope::Container::DBI->connect($dsn, $username, $password, {
      RaiseError => 1,
      Callbacks  => {
          connected => sub {
              shift->do(q{SET NAMES utf8});
          },
      },
  });

=item USING DBI SUBCLASSES

There is two way of using DBI subclass with Scope::Container::DBI. One is DBI's RootClass attribute, other is $Scope::Container::DBI::DBI_CLASS.

  # use RootClass

  my $dbh = Scope::Container::DBI->connect($dsn, $username, $password, {
      RootClass => 'MySubDBI',
  });

  # use $Scope::Container::DBI::DBI_CLASS

  local $Scope::Container::DBI::DBI_CLASS = 'MySubDBI';
  my $dbh = Scope::Container::DBI->connect($dsn, $username, $password);
  # ref($dbh) is 'MySubDBI::db'

=back

=head1 AUTHOR

Masahiro Nagano E<lt>kazeburo {at} gmail.comE<gt>

=head1 SEE ALSO

L<Scope::Container>, L<Plack::Middleware::Scope::Container>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

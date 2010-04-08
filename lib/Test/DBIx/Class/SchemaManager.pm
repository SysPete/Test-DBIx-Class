package Test::DBIx::Class::SchemaManager; {

	use Moose;
	with 'MooseX::Traits::Pluggable';
	use MooseX::Attribute::ENV;
	use Test::More ();
	use List::MoreUtils qw(uniq);
	use Test::DBIx::Class::Types qw(
		TestBuilder SchemaManagerClass FixtureClass ConnectInfo
	);

	has '+_trait_namespace' => (default => '+Trait');

	has 'force_drop_table' => (
		traits=>['ENV'],
		is=>'rw',
		isa=>'Bool',
		required=>1, 
		default=>0,	
	);

	has 'keep_db' => (
		traits=>['ENV'],
		is=>'ro',
		isa=>'Bool',
		required=>1, 
		default=>0,	
	);

	has 'builder' => (
		is => 'ro',
		isa => TestBuilder,
		required => 1,
	);

	has 'schema_class' => (
		traits => ['ENV'],
		is => 'ro',
		isa => SchemaManagerClass,
		required => 1,
		coerce => 1,
	);

	has 'schema' => (
		is => 'ro',
		init_arg => undef,
		lazy_build => 1,
	);

	has 'connect_info' => (
		is => 'ro',
		isa => ConnectInfo,
		coerce => 1,
		lazy_build => 1,
	);

	has 'fixture_class' => (
		traits => ['ENV'],
		is => 'ro',
		isa => FixtureClass,
		required => 1,
		coerce => 1,
		default => '::Populate',		
	);

	has 'fixture_command' => (
		is => 'ro',
		init_arg => undef,
		lazy_build => 1,
	);

	has 'fixture_sets' => (
		is => 'ro',
		isa => 'HashRef',
	);

	has 'last_statement' => (
		is=>'rw',
		isa=>'Str',
	);

	sub get_fixture_sets {
		my ($self, @sets) = @_;
		my @return;
		foreach my $set (@sets) {
			if(my $fixture = $self->fixture_sets->{$set}) {
				push @return, $fixture;
			}
		}
		return @return;
	}

	sub _build_schema {
		my $self = shift @_;
		my $schema_class = $self->schema_class;
		my $connect_info = $self->connect_info;

		$schema_class = $self->prepare_schema_class($schema_class);

		return $schema_class->connect($connect_info);
	}

	sub _build_connect_info {
		my ($self) = @_;
		if(my $default = $self->can('get_default_connect_info') ) {
			return $self->$default;
		} else {
			Test::More::fail("Can't build a default connect info");
		}
	}

	sub _build_fixture_command {
		my $self = shift @_;
		return $self->fixture_class->new(schema_manager=>$self);
	}

	sub prepare_schema_class {
		my ($self, $schema_class) = @_;
		return $schema_class;
	}

	sub initialize_schema {
		my ($class, $config) = @_;

		my @traits = ();
		if(defined $config->{traits}) {
			@traits = ref $config->{traits} ? @{$config->{traits}} : ($config->{traits});
		}

		if(my $connect_info = $config->{connect_info}) {
			$connect_info = to_ConnectInfo($connect_info);
			my ($driver) = $connect_info->{dsn} =~ /dbi:([^:]+):/i;
                        if(lc $driver eq "sqlite") {
                            push @traits, 'SQLite';    
                        }
                        # Don't assume mysql means we want Testmysqld; we may
                        # want to connect to a real mysql server to test.
		} else {
			push @traits, 'SQLite'
			  unless @traits;
		}
		@traits = uniq @traits;
		$config->{traits} = \@traits;
		my $self = $class->new_with_traits($config);

		if($self) {
			$self->schema->storage->ensure_connected; 
			$self->setup;
			return $self;
		} else {
			return;
		}
	}

	## TODO we need to fix DBIC to allow debug levels and channels
	sub _setup_debug {
		my $self = shift @_;
		my $cb = $self->schema->storage->debugcb;

		$self->schema->storage->debug(1);
		$self->schema->storage->debugcb(sub {
			$cb->(@_) if $cb;
			$self->last_statement($_[1]);
		});
	}

	sub setup {
		my $self = shift @_;
		my $deploy_args = $self->force_drop_table ? {add_drop_table => 1} : {};

		if(my $schema = $self->schema) {
			eval {
				$schema->deploy($deploy_args);
			};if($@) {
				Test::More::fail("Error Deploying Schema: $@");
			}
			return $self;
		} 
		return;
	}

	sub cleanup {
		my $self = shift @_;
		my $schema = $self->schema;

		return unless $schema;

		unless ($self->keep_db) {
			$schema->storage->with_deferred_fk_checks(sub {
				foreach my $source ($schema->sources) {
					my $table = $schema->source($source)->name;
					$schema->storage->dbh->do("drop table $table;");
				}
			});
		}

		$self->schema->storage->disconnect;
	}

	sub reset {
		my $self = shift @_;
		$self->cleanup;
		$self->setup;
	}

	sub install_fixtures {
		my ($self, @args) = @_;
		my $fixture_command = $self->fixture_command;
		if(
			(!ref($args[0]) && ($args[0]=~m/^::/))
			or (ref $args[0] eq 'HASH' && $args[0]->{command}) ) {
			my $arg = ref $args[0] ?  $args[0]->{command} : $args[0];
			my $fixture_class = to_FixtureClass($arg);
			$self->builder->diag("Override default FixtureClass '".$self->fixture_class."' with $fixture_class");
			$fixture_command = $fixture_class->new(schema_manager=>$self);
			shift(@args);
		}
		return $self->schema->txn_do( sub {
			$fixture_command->install_fixtures(@args);
		});
	}

	sub DESTROY {
		my $self = shift @_;
		if(defined $self) {
			$self->cleanup;
		}
	}
	
} 1;

__END__

=head1 NAME

Test::DBIx::Class::SchemaManager - Manages a DBIx::Class::SchemaManager for Testing

=head1 DESCRIPTION

This class is a helper for L<Test::DBIx::Class>.  Basically it is a type of
wrapper or adaptor for your schema so we can more easily and quickly deploy it
and cleanup it for the purposes of automated testing.

You shouldn't need to use anything here.  However, we do define %ENV variables
that you might be interested in using (although its probably best to define
inline configuration or use a configuration file).

=over 4

=item FORCE_DROP_TABLE

Set to a true value will force dropping tables in the deploy phase.  This will
generate warnings in a database (like sqlite) that can't detect if a table 
exists before attempting to drop it.  Safe for Mysql though.

=item KEEP_DB

Usually at the end of tests we cleanup your database and remove all the tables
created, etc.  Sometimes you might want to preserve the database after testing
so that you can 'poke around'.  Personally I think it's better to write tests
for the poking, but sometimes you just need a quick look.

=back

=head1 SEE ALSO

The following modules or resources may be of interest.

L<DBIx::Class>, L<Test::DBIx::Class>

=head1 AUTHOR

John Napiorkowski C<< <jjnapiork@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009, John Napiorkowski C<< <jjnapiork@cpan.org> >>

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


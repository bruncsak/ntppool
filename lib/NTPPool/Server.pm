package NTPPool::Server;
use strict;
use base qw(NTPPool::DBI);
use NTPPool::Server::Score;
use NTPPool::Zone;
use RRDs;

__PACKAGE__->set_up_table('servers');
__PACKAGE__->has_a('admin' => 'NTPPool::Admin');
__PACKAGE__->has_many('log_scores' => 'NTPPool::Server::LogScore');
__PACKAGE__->has_many('locations' => 'NTPPool::Location');
__PACKAGE__->has_many('urls'      => [ 'NTPPool::Server::URL' => 'url' ]);
__PACKAGE__->might_have('_score'  => 'NTPPool::Server::Score');

__PACKAGE__->add_trigger( after_create => \&setup_rrd );

__PACKAGE__->set_sql(check_due => qq{
                     SELECT s.id
                         FROM servers s, scores sc
                         WHERE s.id=sc.server
                              and sc.ts < DATE_SUB( NOW(), INTERVAL 29 minute)
                         ORDER BY sc.ts
               });

sub setup_rrd {
    my $self = shift;
    my $ls = $self->add_to_log_scores({ step => 1, score => 0, offset => 0 });
    $self->update_graphs;
}

sub zones {
  my $self = shift;
  sort { $a->name cmp $b->name } map { $_->zone } $self->locations;
}

sub score_raw {
  my $self = shift;
  my ($score) = $self->_score;
  if (@_) {
      $score ||= NTPPool::Server::Score->create({ server => $self });
      $score->score(shift @_);
      $score->update;
  }
  $score = $score ? $score->score : 0;
}

sub score {
  my $self = shift;
  sprintf "%0.1f", $self->score_raw;
}

sub history {
  my ($self, $count) = @_;

  $count ||= 50;

  my $pager = NTPPool::Server::LogScore->pager;
  $pager->page(1);
  $pager->per_page($count);
  $pager->order_by('ts desc');
  $pager->search_where({ server => $self->id });

}

sub find_server {
  my ($class, $arg) = @_;
  my $server;
  ($server) = $class->retrieve($arg) if ($arg =~ m/^\d+$/);
  ($server) = $class->search(ip => $arg) unless $server; 
  ($server) = $class->search(hostname => $arg) unless $server;
  $server;
}

my $rrd_path = "$ENV{CBROOTLOCAL}/rrd/server";
sub rrd_path {
    my $self = shift;
    "$rrd_path/" . $self->id . ".rrd";
}

sub graph_filename {
    my ($self, $name) = @_;
    $self->id . ($name ? "-$name" : "") . ".png";
}

sub graph_path {
    my $self = shift;
   "$rrd_path/graph/" . $self->graph_filename(@_);
}

sub graph_uri {
    my $self = shift;
    "/scores/graph/" . $self->graph_filename(@_);
} 

sub update_graphs {
    my $server = shift;

    my @defaults = (
                    '--lazy',
                    '--end'    => 'now',
                    '--start'  => 'end-10d',
                    '--width'  => 420,
                    '--height' => 130,
                   );

    offset_graph($server, \@defaults);
    score_graph($server, \@defaults);
}

sub score_graph {
    my ($server, $defaults) = @_;

    my $path = $server->graph_path('score');
    my $rrd  = $server->rrd_path;

    my $title = "Score history for " . $server->ip;

    my @options = (@$defaults,
                   '--height' => 160,
                   '--title'  => $title,
                   '--lower-limit' => -10,
                   '--upper-limit' => 20,
#                   '--alt-autoscale-max',
                   '--slope-mode',
                   qq[DEF:score=$rrd:score:AVERAGE],
                   qq[DEF:step=$rrd:step:AVERAGE],
                   q[CDEF:step_blue=step,1,LT,INF,0,IF],
                   q[CDEF:step_yellow=step,0.6,LT,INF,0,IF],
                   q[CDEF:step_orange=step,-0.9,LT,INF,0,IF],
                   q[CDEF:step_red=step,-3.9,LT,INF,0,IF],
                   q[CDEF:step_white=step,0,EQ,INF,0,IF],

                   qq[AREA:step_blue#9999FF:],
                   qq[AREA:step_yellow#EEEE33:],
                   qq[AREA:step_orange#FFAA22:],
                   qq[AREA:step_red#FF6666:],
                   qq[AREA:step_white#FFFFFF],
                   q[LINE2:5#660000:Bad server cutoff],
                   q[LINE1:20#000000:],
                   qq[LINE2:score#00BB00:Score],
#                   qq[LINE1:step#001100:Step],
                  );

    RRDs::graph $path, @options;
    my $ERROR = RRDs::error;
    if ($ERROR) {
        warn "$0: unable to create '$path': $ERROR\n";
    }
}


sub offset_graph {
    my ($server, $defaults) = @_;

    my $path = $server->graph_path('offset');
    my $rrd  = $server->rrd_path;

    my $title = "Offset history for " . $server->ip;

    my @options = (@$defaults,
                   '--width'  => 420,
                   '--height' => 130,
                   '--title'  => $title,
                   '--alt-autoscale-max',
                   '--slope-mode',
                   qq[DEF:score=$rrd:score:AVERAGE],
                   qq[DEF:offset_avg=$rrd:offset:AVERAGE],
                   qq[DEF:offset_top=$rrd:offset:MAX],
                   qq[DEF:offset_bot=$rrd:offset:MIN],
                   
                   #qq[CDEF:offset_top_smooth=offset_top,7200,TREND],
                   #qq[CDEF:offset_bot_smooth=offset_bot,7200,TREND],

                   q[CDEF:offset_area=offset_top,offset_bot,-],

                   q[LINE1:offset_bot#00FF00:Minimum offset],
                   q[AREA:offset_area#FFBFBF::STACK],  
                   q[LINE1:offset_top#FF0000:Maximum offset],
                   q[LINE1:offset_avg#000000:Offset],
                      
                  );

    RRDs::graph $path, @options;
    my $ERROR = RRDs::error;
    if ($ERROR) {
        warn "$0: unable to create '$path': $ERROR\n";
    }
}


1;

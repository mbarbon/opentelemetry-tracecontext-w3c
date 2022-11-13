package OpenTelemetry::TraceContext::W3C;
# ABSTRACT: W3C Trace Context implementation

use strict;
use warnings;
use Exporter qw();

# VERSION

*import = \&Exporter::import;

our @EXPORT_OK = qw(
    parse_traceparent
    format_traceparent
    format_traceparent_v00

    parse_tracestate
    format_tracestate
    update_tracestate
    format_tracestate_v00
);
our %EXPORT_TAGS = (
    all     => \@EXPORT_OK,
);

my $match_traceparent_v0 = do {
    my $h = '[0-9a-f]';

    qr{^(${h}{2})-(${h}{32})-(${h}{16})-(${h}{2})(-|\z)};
};
my $invalid_trace_id = '0' x 32;
my $invalid_parent_id = '0' x 16;

my $match_tracestate_listmember_v0 = do {
    my $a = '[a-z]';
    my $ad = '[a-z0-9]';
    my $id_char = '[a-z0-9_*/-]';

    my $vc  = '[\x20-\x2b\x2d-\x3c\x3e-\x7e]';
    my $vnb = '[\x21-\x2b\x2d-\x3c\x3e-\x7e]';

    qr{(?:(${a}${id_char}{0,255})|(${ad}${id_char}{0,240})@(${a}${id_char}{0,13}))=(${vc}{0,255}${vnb})};
};

sub parse_traceparent {
    my ($value) = @_;

    if ($value !~ $match_traceparent_v0) {
        return undef;
    }

    my ($version, $trace_id, $parent_id, $trace_flags, $next_char) =
        (hex $1, $2, $3, hex $4, $5);
    if ($version == 0xff || ($version == 0x00 && $next_char ne '')) {
        return undef;
    }
    if ($trace_id eq $invalid_trace_id || $parent_id eq $invalid_parent_id) {
        return undef;
    }

    return {
        version     => $version,
        trace_id    => $trace_id,
        parent_id   => $parent_id,
        trace_flags => $trace_flags,
    };
}

sub format_traceparent_v00 {
    my ($parsed) = @_;
    my ($trace_id, $parent_id) = ($parsed->{trace_id}, $parsed->{parent_id});

    if (!$trace_id || length($trace_id) != 32 || $trace_id eq $invalid_trace_id) {
        return undef;
    }
    if (!$parent_id || length($parent_id) != 16 || $parent_id eq $invalid_parent_id) {
        return undef;
    }

    return sprintf "00-%s-%s-%02d", $trace_id, $parent_id, $parsed->{trace_flags} & 0x01;
}

sub parse_tracestate {
    my ($value) = @_;
    my @parts = split /[\x20\x09]*,[\x20\x09]*/, $value;

    # TODO check
    # if there are more than 32 parts it is not clear if the whole header
    # should be considered invalid, or whether it should be truncated to 32,
    # I'm picking the latter here
    $#parts = 31 if $#parts > 31;

    my @list_members;
    for my $part (@parts) {
        my $list_member = _make_tracestate_list_member($part);
        next unless $list_member;

        push @list_members, $list_member;
    }

    return { list_members => \@list_members };
}

sub format_tracestate_v00 {
    my ($parsed, $options) = @_;
    my $max_length = $options ? $options->{max_length} // 512 : 512;
    my $formatted = join ',', map "$_->{key}=$_->{value}", @{$parsed->{list_members}};

    if (length($formatted) > $max_length) {
        my @chopping_list = map [length($_->{key}) + length($_->{value}) + 2, $_], @{$parsed->{list_members}};
        my $length = length($formatted);

        for (my $i = $#chopping_list; $i >= 0 && $length > $max_length; --$i) {
            next if $chopping_list[$i][0] < 129;
            $length -= $chopping_list[$i][0];
            splice @chopping_list, $i, 1;
        }

        while (@chopping_list && $length > $max_length) {
            $length -= $chopping_list[-1][0];
            pop @chopping_list;
        }

        $formatted = join ',', map "$_->[1]{key}=$_->[1]{value}", @chopping_list;
    }

    return $formatted;
}

sub update_tracestate {
    my ($parsed, $key, $value) = @_;

    my $list_member = _make_tracestate_list_member("${key}=${value}");
    return 0 unless $list_member;

    for my $i (0 .. $#{$parsed->{list_members}}) {
        if ($parsed->{list_members}[$i]{key} eq $list_member->{key}) {
            splice @{$parsed->{list_members}}, $i , 1;
            last;
        }
    }

    unshift @{$parsed->{list_members}}, $list_member;
    $#{$parsed->{list_members}} = 31 if $#{$parsed->{list_members}} > 31;

    return 1;
}

sub _make_tracestate_list_member {
    my ($formatted_string) = @_;

    if ($formatted_string !~ $match_tracestate_listmember_v0) {
        return undef;
    }

    my ($simple_key, $tenant_id, $system_id, $value) = ($1, $2, $3, $4);
    return {
        !$simple_key ? () : ( key  => $simple_key ),
        !$tenant_id ? () : (
            key         => "${tenant_id}\@${system_id}",
            tenant_id   => $tenant_id,
            system_id   => $system_id,
        ),
        value       => $value,
    };
}

*format_traceparent = \&format_traceparent_v00;
*format_tracestate = \&format_tracestate_v00;

1;

__END__

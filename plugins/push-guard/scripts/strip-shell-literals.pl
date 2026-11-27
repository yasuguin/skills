#!/usr/bin/env perl
# Bash コマンド文字列から、実行されない文字列を除いて標準出力へ返す (危険パターンの照合用)。
# 除くのは heredoc の本文と引用符 ('...' "..." $'...') の中身。危険パターンを説明する commit
# メッセージや grep の検索語が、コマンドとして照合されて止まるのを防ぐため。
# シェルに渡される文字列は実行されるので残す: bash/sh/zsh -c の引数、eval の引数、bash/sh/zsh が
# 受ける heredoc の本文、"$(...)" と `...` の中身。残した箇所の前後は空白にして、照合規則の
# 単語境界 ([[:space:];&|]) に掛かるようにする。
# パイプで shell に流す文字列は引用符の中身も実行されうるため、加工せず元の文字列を返す。
use strict;
use warnings;

my $SHELL = qr{^(?:\S*/)?(?:bash|sh|zsh)$};
my %PREFIX = map { $_ => 1 } qw(env command builtin exec nohup time sudo nice xargs);

# 引用符より前の生テキストから、実際に呼ばれるコマンドの単語列を返す
sub command_words {
    my @w = grep { length } split /\s+/, $_[0];
    shift @w while @w && ($PREFIX{$w[0]} || $w[0] =~ /^-/ || $w[0] =~ /^[A-Za-z_]\w*=/);
    return @w;
}

# 直後の引用符の中身がシェルの入力になるか (eval の引数、または bash -c 系の -c の後ろ)
sub runs_shell {
    my @w = command_words($_[0]);
    return 0 unless @w;
    return 1 if $w[0] eq 'eval';
    return 0 unless $w[0] =~ $SHELL;
    return scalar grep { /^-[A-Za-z]*c[A-Za-z]*$/ } @w[1 .. $#w];
}

# heredoc の演算子の行で、本文の入力先がシェルになるか (cat <<EOF | bash など)
sub line_feeds_shell {
    for my $piece (split /[;&|()`]/, $_[0]) {
        my @w = command_words($piece);
        return 1 if @w && ($w[0] eq 'eval' || $w[0] =~ $SHELL);
    }
    return 0;
}

sub strip_literals {
    my ($in) = @_;
    my $n = length $in;
    # code: 最上位 / P: $( ... ) / B: `...` / S: '...' / D: "..." / A: $'...'
    # keep: シェルに渡す文字列として中身を残す (子の文脈へ引き継ぐ)
    my @stack = ({ t => 'code', keep => 0, seg => 0, depth => 0 });
    my @pending;
    my $out = '';
    my $i = 0;

    while ($i < $n) {
        my $c   = substr($in, $i, 1);
        my $ctx = $stack[-1];
        my $t   = $ctx->{t};
        my $code = $t eq 'code' || $t eq 'P' || $t eq 'B';
        my $live = $code || $ctx->{keep};

        # 改行の直後から保留中の heredoc の本文を順に読む。終端が無ければ残りを本文とみなす
        if ($c eq "\n" && @pending) {
            $out .= "\n";
            $i++;
            for my $h (@pending) {
                while ($i < $n) {
                    my $eol = index($in, "\n", $i);
                    $eol = $n if $eol < 0;
                    my $line = substr($in, $i, $eol - $i);
                    $out .= $line . ($eol < $n ? "\n" : '') if $h->{keep};
                    $i = $eol < $n ? $eol + 1 : $n;
                    my $cmp = $h->{strip} ? ($line =~ s/^\t+//r) : $line;
                    last if $cmp eq $h->{word};
                }
            }
            @pending = ();
            $ctx->{seg} = $i if $code;
            next;
        }

        if ($t eq 'S') {
            if ($c eq "'") { $out .= $ctx->{keep} ? ' ' : "'"; pop @stack; }
            else           { $out .= $c if $live; }
            $i++;
            next;
        }

        if ($t eq 'A') {
            if ($c eq '\\') { $out .= substr($in, $i, 2) if $live; $i += 2; next; }
            if ($c eq "'")  { $out .= $ctx->{keep} ? ' ' : "'"; pop @stack; }
            else            { $out .= $c if $live; }
            $i++;
            next;
        }

        if ($t eq 'D') {
            if ($c eq '\\') { $out .= substr($in, $i, 2) if $live; $i += 2; next; }
            if ($c eq '"') { $out .= $ctx->{keep} ? ' ' : '"'; pop @stack; $i++; next; }
            if ($c eq '$' && substr($in, $i + 1, 1) eq '(') {
                push @stack, { t => 'P', keep => $ctx->{keep}, seg => $i + 2, depth => 0 };
                $out .= '$( ';
                $i += 2;
                next;
            }
            if ($c eq '`') {
                push @stack, { t => 'B', keep => $ctx->{keep}, seg => $i + 1, depth => 0 };
                $out .= '` ';
                $i++;
                next;
            }
            $out .= $c if $live;
            $i++;
            next;
        }

        # code / P / B
        if ($c eq '\\') { $out .= substr($in, $i, 2); $i += 2; next; }

        if ($c eq "'" || $c eq '"' || ($c eq '$' && substr($in, $i + 1, 1) eq "'")) {
            my $ansi   = $c eq '$';
            my $prefix = substr($in, $ctx->{seg}, $i - $ctx->{seg});
            my $keep   = ($ctx->{keep} || runs_shell($prefix)) ? 1 : 0;
            my $kind   = $ansi ? 'A' : $c eq "'" ? 'S' : 'D';
            push @stack, { t => $kind, keep => $keep, seg => 0, depth => 0 };
            if    ($keep) { $out .= ' ' }
            elsif ($ansi) { $out .= "\$'" }
            else          { $out .= $c }
            $i += $ansi ? 2 : 1;
            next;
        }

        if ($c eq '$' && substr($in, $i + 1, 1) eq '(') {
            push @stack, { t => 'P', keep => $ctx->{keep}, seg => $i + 2, depth => 0 };
            $out .= '$( ';
            $i += 2;
            next;
        }

        if ($c eq '`') {
            if ($t eq 'B') { pop @stack; $out .= ' `'; }
            else {
                push @stack, { t => 'B', keep => $ctx->{keep}, seg => $i + 1, depth => 0 };
                $out .= '` ';
            }
            $i++;
            next;
        }

        # heredoc の開始。<<< や 1<<2 (算術) は対象外
        if ($c eq '<' && substr($in, $i, 2) eq '<<' && substr($in, $i + 2, 1) ne '<'
            && ($i == 0 || substr($in, $i - 1, 1) !~ /[<0-9]/)) {
            if (substr($in, $i) =~ /^(<<(-?)[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|\\?([A-Za-z_][^\s;&|<>()'"`]*)))/) {
                my ($m, $dash) = ($1, $2);
                my $word = defined $3 ? $3 : defined $4 ? $4 : $5;
                my $ls = $i > 0 ? rindex($in, "\n", $i - 1) + 1 : 0;
                my $le = index($in, "\n", $i);
                $le = $n if $le < 0;
                my $keep = ($ctx->{keep} || line_feeds_shell(substr($in, $ls, $le - $ls))) ? 1 : 0;
                push @pending, { word => $word, strip => $dash eq '-', keep => $keep };
                $out .= $m;
                $i += length $m;
                next;
            }
        }

        # 単語の先頭の # は行末までコメント (中の引用符で文脈を狂わせない)
        if ($c eq '#' && ($i == 0 || substr($in, $i - 1, 1) =~ /[\s;&|(`]/)) {
            my $eol = index($in, "\n", $i);
            $eol = $n if $eol < 0;
            $out .= substr($in, $i, $eol - $i);
            $i = $eol;
            next;
        }

        if ($c =~ /[;&|()\n]/) {
            if ($t eq 'P' && $c eq '(') { $ctx->{depth}++; }
            elsif ($t eq 'P' && $c eq ')') {
                if ($ctx->{depth} > 0) { $ctx->{depth}--; }
                else { pop @stack; $out .= ')'; $i++; next; }
            }
            $out .= $c;
            $ctx->{seg} = $i + 1;
            $i++;
            next;
        }

        $out .= $c;
        $i++;
    }
    return $out;
}

my $in = do { local $/; <STDIN> };
$in = '' unless defined $in;

if ($in =~ /\|\s*(?:(?:env|command|exec|sudo|xargs)\s+(?:-\S+\s+)*)*(?:\S*\/)?(?:ba|z)?sh\b/) {
    print $in;
    exit 0;
}

my $out = eval { strip_literals($in) };
if (!defined $out) {
    print STDERR "strip-shell-literals: $@";
    exit 1;
}
print $out;

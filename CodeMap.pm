# Copyright 2016 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use utf8;
use warnings;

use FindBin;
use lib $FindBin::Bin;

use ReadCodes;

package CodeMap;

my $ordered_key_values =
    'aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ;:,<.>/?';
if (ReadCodes::keyboard_layout('jpn')) {
    $ordered_key_values =~ s/:/+/;
}

my %key_to_number;
for my $key_index (0..(length($ordered_key_values) - 1)) {
    my $key = substr($ordered_key_values, $key_index, 1);
    $key_to_number{$key} = $key_index;
}

sub new {
    my ($class) = @_;

    return bless {
        # 定議されている全コードの最初の１～２文字 => 1
        # 文字列ｆｏｏ＋（任意のキー）が有効なコードかどうかを速く調べるために
        # 使う
        code_prefixes => {},

        # 2~3打鍵コードの文字列 => 実際に入力される文字・文字列
        codes => {},

        register_later => [],
    }, $class;
}

sub _register_finding_empty {
    my ($self, $key, $value) = @_;
    my $first_two_keys = substr($key, 0, 2);
    my $last_key = substr($key, 2);
    for (1..length($ordered_key_values)) {
        return if $self->write_code($first_two_keys . $last_key, $value);
        $self->increment_key(\$last_key, 1);
    }
    die "No free codes starting with $first_two_keys";
}

sub _process_register_later {
    my ($self) = @_;
    for my $later (sort(@{$self->{register_later}})) {
        $self->_register_finding_empty(split "\t", $later);
    }
    @{$self->{register_later}} = ();
}

# 一文字の漢字入力キーとしての値をずらす。
sub increment_key {
    my ($self, $key, $amount) = @_;
    my $value = $key_to_number{$$key};
    $$key = $self->number_to_key($value + $amount);
}

sub number_to_key {
    my ($self, $value) = @_;
    $value %= length($ordered_key_values);
    return substr($ordered_key_values, $value, 1);
}

sub write_code {
    my ($self, $key, $value) = @_;
    return 0 if defined($self->{codes}->{$key});
    $self->{codes}->{$key} = $value;
    while ($key =~ s/.$// && $key) {
        $self->{code_prefixes}->{$key} = 1;
    }
    return 1;
}

sub is_code_prefix {
    my ($self, $prefix) = @_;
    return $self->{code_prefixes}->{$prefix};
}

sub register {
    my ($self, $key, @values) = @_;
    for my $value (@values) {
        if (!$self->write_code($key, $value)) {
            push(@{$self->{register_later}}, "$key\t$value");
        }
    }
}

sub lookup {
    my ($self, $key) = @_;
    $self->_process_register_later();
    return $self->{codes}->{$key};
}

sub code_by_kanji {
    my ($self) = @_;
    $self->_process_register_later();
    return reverse %{$self->{codes}};
}

sub register_autogenerated_codes {
    my ($self, %options) = @_;
    $self->_process_register_later();

    my $type_kanji_in_caps = $options{TYPE_KANJI_IN_CAPS} // 1;
    my $type_katakana_in_caps = $options{TYPE_KATAKANA_IN_CAPS} // 1;

    for my $key (keys %{$self->{codes}}) {
        next if $key !~ m/^(.)i$/;
        my $first_key = $1;
        my $first_kana = $self->lookup($key);
        my %number_substs = qw(
            7 ゃ
            8 ゅ
            9 ょ
        );
        while (my ($number, $kana) = each %number_substs) {
            $self->write_code($first_key . $number,
                              "${first_kana}${kana}");
            $self->write_code($first_key . ReadCodes::shift_last_char($number),
                              "${first_kana}${kana}う");
        }
    }

    # ２文字コードの前に数字を入れてかなを効率良く入力できるようにする
    for my $key (keys %{$self->{codes}}) {
        next if length($key) != 2;

        my $value = $self->lookup($key);

        # カナじゃなけりゃ数字による省略ができない。
        # これで意味ありげなコード (2]s -> い」) が幾つか無効になりますがグー
        # グル日本語入力にかな変換テーブルの制限があるため、一応省略します。
        next if $value !~ m/^[ぁ-ゖ]+$/;

        my %number_substs = qw(
            1 っ
            2 い
            3 あ
            4 う
            5 え
            6 お
            0 ん
        );
        while (my ($number, $kana) = each %number_substs) {
            my $new_key = $number . $key;
            $new_key =~ s/;//;
            $self->write_code($new_key, $kana . $value);
        }
    }

    # カタカナのコードをひらがなのコードから自動生成する
    # 尚、CAPSLOCKがオンでも一般の漢字を入力できるようにする
    for my $key (keys %{$self->{codes}}) {
        my $ukey = $key;
        $ukey =~ tr/a-zA-Z/A-Za-z/;
        my $uvalue = $self->lookup($key);
        if ($uvalue =~ tr/ぁ-ゖ/ァ-ヶ/) {
            next if !$type_katakana_in_caps;
        } else {
            next if !$type_kanji_in_caps;
        }
        $self->write_code($ukey, $uvalue);
    }

    # 全角文字を【＇】（英語キーボード）か【：】で入力できるようにする。
    my $full_width_key = ReadCodes::keyboard_layout('jpn') ? q{:} : q{'};
    for my $half_width_ord (ord('!')..ord('~')) {
        my $half_width = chr($half_width_ord);
        my $full_width = chr($half_width_ord + 0xfee0);
        $self->write_code("$full_width_key$half_width", $full_width);
    }
}

1;

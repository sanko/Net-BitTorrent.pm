use v5.40;
use Test2::V1 -ipP;
no warnings;
use lib '../lib';

BEGIN {
    try {
        require Crypt::PK::DH;
        require Crypt::Stream::RC4;
    }
    catch ($e) {
        plan skip_all => 'Crypt::PK::DH and Crypt::Stream::RC4 required for MSE tests';
    }
}
use Net::BitTorrent::Protocol::MSE;
#
my $ih        = 'I' x 20;
my $initiator = Net::BitTorrent::Protocol::MSE->new( info_hash => $ih, is_initiator => 1 );
my $receiver  = Net::BitTorrent::Protocol::MSE->new( info_hash => $ih, is_initiator => 0 );

# Initiator sends PubKeyA
my $buf_a = $initiator->write_buffer;
my $len_a = length($buf_a);
ok( ( $len_a >= 96 && $len_a <= 608 ), 'Initiator sends ' . $len_a . '-byte PubKeyA + PadA' );

# Receiver receives PubKeyA, sends PubKeyB
$receiver->receive_data($buf_a);
my $buf_b = $receiver->write_buffer;
my $len_b = length($buf_b);
ok( ( $len_b >= 96 && $len_b <= 608 ), 'Receiver sends ' . $len_b . '-byte PubKeyB + PadB' );

# Initiator receives PubKeyB, sends Req1, Req2^3, and ENCRYPT(VC...)
$initiator->receive_data($buf_b);
my $buf_req = $initiator->write_buffer;

# Req1(20) + Req2^3(20) + Enc(VC(8)+Crypto(4)+PadC(2)+IA(2)) = 20 + 20 + 16 = 56
is length($buf_req),  56,          'Initiator sends 56-byte request block';
is $initiator->state, 'A_WAIT_VC', 'Initiator is now in A_WAIT_VC state';

# Receiver receives request block, sends B_SEND_SELECT
$receiver->receive_data($buf_req);
is $receiver->state, 'PAYLOAD', 'Receiver is now in PAYLOAD state';
my $buf_sel = $receiver->write_buffer;

# Enc(VC(8)+Crypto(4)+PadD(2)) = 14
is length($buf_sel), 14, 'Receiver sends 14-byte select block';

# Initiator receives B_SEND_SELECT
$initiator->receive_data($buf_sel);
is $initiator->state, 'PAYLOAD', 'Initiator is now in PAYLOAD state after receiving select';

# Test encrypted communication
my $secret_msg = 'Hello MSE World';
my $encrypted  = $initiator->encrypt_data($secret_msg);
isnt $encrypted, $secret_msg, 'Message is encrypted';

# Initiator's data must be decrypted by Receiver
# Wait, in the test we need to handle the B_SEND_SELECT on Initiator side if we were being strict
# but our simplified Initiator jumped to PAYLOAD.
my $decrypted = $receiver->decrypt_data($encrypted);
is $decrypted, $secret_msg, 'Receiver decrypted the message correctly';
#
done_testing;

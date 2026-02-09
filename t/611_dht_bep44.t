use v5.40;
use lib 'lib', '../lib';
use Test2::V0;
use Net::BitTorrent::DHT;
use Net::BitTorrent::DHT::Security;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bdecode bencode];
use Digest::SHA                               qw[sha1];
#
my $sec = Net::BitTorrent::DHT::Security->new();
my $id  = $sec->generate_node_id('127.0.0.1');
my $dht = Net::BitTorrent::DHT->new( node_id_bin => $id, bep44 => 1, port => 0 );

# Mock _send_raw
my $sent_data;
no warnings 'redefine';
local *Net::BitTorrent::DHT::_send_raw = sub {
    my ( $self, $data, $dest ) = @_;
    $sent_data = $data;
};

#~ use warnings 'redefine';
subtest 'Immutable data' => sub {
    my $v      = 'Hello, world!';
    my $target = sha1($v);
    my $token  = $dht->_generate_token('127.0.0.1');

    # Store immutable data
    $dht->_handle_query( { t => 'pt1', y => 'q', q => 'put', a => { id => $sec->generate_node_id('127.0.0.1'), v => $v, token => $token } },
        'dummy', '127.0.0.1', 1234 );

    # Retrieve immutable data
    $sent_data = undef;
    $dht->_handle_query( { t => 'gt1', y => 'q', q => 'get', a => { id => $sec->generate_node_id('1.2.3.4'), target => $target } },
        'dummy', '1.2.3.4', 4321 );
    my $res = bdecode($sent_data);
    is $res->{r}{v}, $v, 'Retrieved correct immutable value';
};
subtest 'Mutable data' => sub {
    my $backend;
    try { require Crypt::PK::Ed25519; $backend = 'Crypt::PK::Ed25519' }
    catch ($e) {
        try {
            require Crypt::Perl::Ed25519::PrivateKey;
            require Crypt::Perl::Ed25519::PublicKey;
            $backend = 'Crypt::Perl';
        }
        catch ($e2) { }
    }
    skip_all 'Cannot enable BEP44. Install Crypt::PK::Ed25519 or Crypt::Perl::Ed25519::PublicKey', 5 unless $backend;
    my ( $pub_key, $v, $seq, $salt, $target, $pk_ed );
    if ( $backend eq 'Crypt::PK::Ed25519' ) {
        $pk_ed = Crypt::PK::Ed25519->new();
        $pk_ed->generate_key();
        $pub_key = $pk_ed->export_key_raw('public');
    }
    else {
        $pk_ed = Crypt::Perl::Ed25519::PrivateKey->new();
        my $tmp_pub = $pk_ed->get_public;
        $pub_key = ref $tmp_pub ? $tmp_pub->encode : $tmp_pub;
    }
    $v      = 'Mutable data';
    $seq    = 1;
    $salt   = 'my salt';
    $target = sha1( $pub_key . $salt );
    my $token = $dht->_generate_token('127.0.0.1');

    # Prepare signature
    # to_sign: 4:salt<bencoded salt>3:seq<bencoded seq>1:v<bencoded v>
    my $to_sign = "4:salt" . bencode($salt) . "3:seq" . bencode($seq) . "1:v" . bencode($v);
    my $sig     = ( $backend eq 'Crypt::PK::Ed25519' ) ? $pk_ed->sign_message($to_sign) : $pk_ed->sign($to_sign);

    # Store mutable data
    $dht->_handle_query(
        {   t => 'pt2',
            y => 'q',
            q => 'put',
            a => { id => $sec->generate_node_id('127.0.0.1'), v => $v, k => $pub_key, seq => $seq, salt => $salt, sig => $sig, token => $token }
        },
        'dummy',
        '127.0.0.1',
        1234
    );

    # Retrieve mutable data
    $sent_data = undef;
    $dht->_handle_query( { t => 'gt2', y => 'q', q => 'get', a => { id => $sec->generate_node_id('1.2.3.4'), target => $target } },
        'dummy', '1.2.3.4', 4321 );
    my $res = bdecode($sent_data);
    is $res->{r}{v},   $v,       'Retrieved correct mutable value';
    is $res->{r}{seq}, $seq,     'Retrieved correct sequence number';
    is $res->{r}{k},   $pub_key, 'Retrieved correct public key';

    # Test CAS and Sequence validation
    my $new_v       = 'Updated data';
    my $new_seq     = 2;
    my $new_to_sign = "4:salt" . bencode($salt) . "3:seq" . bencode($new_seq) . "1:v" . bencode($new_v);
    my $new_sig     = ( $backend eq 'Crypt::PK::Ed25519' ) ? $pk_ed->sign_message($new_to_sign) : $pk_ed->sign($new_to_sign);

    # Update with invalid CAS (signature is valid for this CAS, but CAS doesn't match storage)
    my $bad_cas         = 999;
    my $bad_cas_to_sign = "3:cas" . bencode($bad_cas) . "4:salt" . bencode($salt) . "3:seq" . bencode($new_seq) . "1:v" . bencode($new_v);
    my $bad_cas_sig     = ( $backend eq 'Crypt::PK::Ed25519' ) ? $pk_ed->sign_message($bad_cas_to_sign) : $pk_ed->sign($bad_cas_to_sign);
    $dht->_handle_query(
        {   t => 'pt3',
            y => 'q',
            q => 'put',
            a => {
                id    => $sec->generate_node_id('127.0.0.1'),
                v     => $new_v,
                k     => $pub_key,
                seq   => $new_seq,
                salt  => $salt,
                sig   => $bad_cas_sig,
                token => $token,
                cas   => $bad_cas                               # Wrong CAS
            }
        },
        'dummy',
        '127.0.0.1',
        1234
    );

    # Verify NOT updated
    $dht->_handle_query( { t => 'gt3', y => 'q', q => 'get', a => { id => $sec->generate_node_id('1.2.3.4'), target => $target } },
        'dummy', '1.2.3.4', 4321 );
    $res = bdecode($sent_data);
    is $res->{r}{v}, $v, 'Value not updated due to invalid CAS';

    # Update with valid CAS (must include CAS in signature)
    my $cas_to_sign = "3:cas" . bencode($seq) . "4:salt" . bencode($salt) . "3:seq" . bencode($new_seq) . "1:v" . bencode($new_v);
    my $cas_sig     = ( $backend eq 'Crypt::PK::Ed25519' ) ? $pk_ed->sign_message($cas_to_sign) : $pk_ed->sign($cas_to_sign);
    $dht->_handle_query(
        {   t => 'pt4',
            y => 'q',
            q => 'put',
            a => {
                id    => $sec->generate_node_id('127.0.0.1'),
                v     => $new_v,
                k     => $pub_key,
                seq   => $new_seq,
                salt  => $salt,
                sig   => $cas_sig,
                token => $token,
                cas   => $seq                                   # Valid CAS
            }
        },
        'dummy',
        '127.0.0.1',
        1234
    );

    # Verify updated
    $dht->_handle_query( { t => 'gt4', y => 'q', q => 'get', a => { id => $sec->generate_node_id('1.2.3.4'), target => $target } },
        'dummy', '1.2.3.4', 4321 );
    $res = bdecode($sent_data);
    is $res->{r}{v}, $new_v, 'Value updated correctly with valid CAS';
    subtest 'Invalid signature/key' => sub {
        my $bad_v       = 'Malicious update';
        my $bad_seq     = 100;
        my $bad_to_sign = "4:salt" . bencode($salt) . "3:seq" . bencode($bad_seq) . "1:v" . bencode($bad_v);

        # Generate a DIFFERENT key pair
        my ( $other_pk, $other_pub );
        if ( $backend eq 'Crypt::PK::Ed25519' ) {
            $other_pk = Crypt::PK::Ed25519->new();
            $other_pk->generate_key();
            $other_pub = $other_pk->export_key_raw('public');
        }
        else {
            $other_pk = Crypt::Perl::Ed25519::PrivateKey->new();
            my $tmp_pub = $other_pk->get_public;
            $other_pub = ref $tmp_pub ? $tmp_pub->encode : $tmp_pub;
        }

        # Scenario 1: Correct signature but for a DIFFERENT key targeting the original salt
        # In this implementation, the target is derived from the key provided in the query.
        # So providing a different key just targets a different slot.
        my $other_sig = ( $backend eq 'Crypt::PK::Ed25519' ) ? $other_pk->sign_message($bad_to_sign) : $other_pk->sign($bad_to_sign);
        $dht->_handle_query(
            {   t => 'pt_bad1',
                y => 'q',
                q => 'put',
                a => {
                    id    => $sec->generate_node_id('127.0.0.1'),
                    v     => $bad_v,
                    k     => $other_pub,
                    seq   => $bad_seq,
                    salt  => $salt,
                    sig   => $other_sig,
                    token => $token
                }
            },
            'dummy',
            '127.0.0.1',
            1234
        );

        # Verify ORIGINAL target is unchanged
        $dht->_handle_query( { t => 'gt_check1', y => 'q', q => 'get', a => { id => $sec->generate_node_id('1.2.3.4'), target => $target } },
            'dummy', '1.2.3.4', 4321 );
        $res = bdecode($sent_data);
        is $res->{r}{v}, $new_v, 'Original target remains unchanged when different key is used';

        # Scenario 2: Correct key but INVALID signature
        my $fake_sig = "A" x 64;
        $dht->_handle_query(
            {   t => 'pt_bad2',
                y => 'q',
                q => 'put',
                a => {
                    id    => $sec->generate_node_id('127.0.0.1'),
                    v     => $bad_v,
                    k     => $pub_key,
                    seq   => $bad_seq,
                    salt  => $salt,
                    sig   => $fake_sig,
                    token => $token
                }
            },
            'dummy',
            '127.0.0.1',
            1234
        );

        # Verify ORIGINAL target is still unchanged
        $dht->_handle_query( { t => 'gt_check2', y => 'q', q => 'get', a => { id => $sec->generate_node_id('1.2.3.4'), target => $target } },
            'dummy', '1.2.3.4', 4321 );
        $res = bdecode($sent_data);
        is $res->{r}{v}, $new_v, 'Original target remains unchanged when invalid signature is provided';
        subtest 'Blacklisting' => sub {
            my $malicious_ip    = '1.2.3.5';
            my $malicious_id    = $sec->generate_node_id($malicious_ip);
            my $malicious_token = $dht->_generate_token($malicious_ip);

            # Trigger blacklist with bad signature
            $dht->_handle_query(
                {   t => 'pt_mal',
                    y => 'q',
                    q => 'put',
                    a => { id => $malicious_id, v => 'bad', k => $pub_key, seq => 999, sig => 'invalid', token => $malicious_token }
                },
                'dummy',
                $malicious_ip,
                1234
            );

            # Subsequent VALID query from same IP should be ignored (return undef)
            $sent_data = 'no_change';
            my $result = $dht->_handle_query( { t => 'ping_after_blacklist', y => 'q', q => 'ping', a => { id => $malicious_id } },
                'dummy', $malicious_ip, 1234 );
            is $result,    undef,       'Subsequent query from malicious IP is ignored';
            is $sent_data, 'no_change', 'No response packet sent to blacklisted IP';
        };
    };
};
#
done_testing;

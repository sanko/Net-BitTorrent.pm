use v5.42;
use Test2::V1 -ipP;
no warnings;
use Acme::Bitfield;
subtest 'Bitfield MSB-First' => sub {
    my $bf = Acme::Bitfield->new( size => 10 );
    is $bf->size,  10, 'Size is 10';
    is $bf->count, 0,  'Initial count 0';
    $bf->set(0);    # First bit of first byte (0x80)
    is unpack( 'H*', $bf->data ), '8000', 'Bit 0 is 0x80';
    ok $bf->get(0), 'Get bit 0 is true';
    is $bf->count, 1, 'Count is 1';
    $bf->set(7);    # Last bit of first byte (0x01)
    is unpack( 'H*', $bf->data ), '8100', 'Bit 7 is 0x01';
    is $bf->count,                2,      'Count is 2';
    $bf->set(8);    # First bit of second byte
    is unpack( 'H*', $bf->data ), '8180', 'Bit 8 set';
    $bf->clear(0);
    is $bf->get(0),               0,      'Bit 0 cleared';
    is unpack( 'H*', $bf->data ), '0180', 'Bit 0 cleared in raw data';
};
done_testing;

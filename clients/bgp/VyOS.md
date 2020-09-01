# Configuring VyOS (Vyatta, Edgerouter, etc)

## Assumptions

1. Server IP is 203.9.226.15
2. Server ASN is 64545
3. Your IP is 99.88.77.66
4. Your ASN is 64999
5. 192.168.192.168 is an unused address in your network

## BGP Configuration

This is the 'blackhole' route that bad networks are sent to

    set protocols static route 192.168.192.168/32 blackhole

### Filters

This is the Community string configured in apiban.bird.conf

    set policy community-list apiban rule 10 action 'permit'
    set policy community-list apiban rule 10 regex '64545:888'

When we match that community string, force the distance to be 1 so it
always beats a conflicting route, and then send it to the blackhole
route we created earlier

    set policy route-map APIBAN rule 10 action 'permit'
    set policy route-map APIBAN rule 10 match community community-list 'apiban'
    set policy route-map APIBAN rule 10 set distance '1'
    set policy route-map APIBAN rule 10 set ip-next-hop '192.168.192.168'

This is to make sure you don't send any routes out to the APIBan BGP Instance

    set policy prefix-list REJECTALL rule 10 action deny
    set policy prefix-list REJECTALL rule 10 prefix 0.0.0.0/0

### Peer

64999 is the AS of the local router, 64545 is the AS allocated in Bird. 203.9.226.15 is
the address of the Bird APIBan Server

    set protocols bgp 64999 neighbor 203.9.226.15 address-family ipv4-unicast route-map import 'APIBAN'
    set protocols bgp 64999 neighbor 203.9.226.15 address-family ipv4-unicast prefix-list export 'REJECTALL'
    set protocols bgp 64999 neighbor 203.9.226.15 address-family ipv4-unicast soft-reconfiguration inbound
    set protocols bgp 64999 neighbor 203.9.226.15 ebgp-multihop '255'
    set protocols bgp 64999 neighbor 203.9.226.15 remote-as '64545'



### oparser.sh is a bash script made to support the extraction of the L3VPN Overlay configuration from an MPLS PE router 

0. the first main assumption is that the input configuration is conform with the 'CISCO Formal' format
1. the second main assumption is that the input configuration is including L3VPN configuration sesctions 
2. the script is tested against CISCO-XR v6.2.3 (it should work on newer versions)
3. the Bundle-if format is matched by the following rgx '^Bundle-Ether[0-9]{1,5}\.[0-9]{1,5}|^Bundle-Ether[0-9]{1,5}'
4. for what concerning the script input: both PE's configuration file & Bundle-if are mandatory
5. the Script final output is the PE's overlay configuration divided into multiple files:
	- ./cfgs/level1_vrf.cf        	
	- ./cfgs/level2_pm.cf 	
	- ./cfgs/level1_if.cf  	
	- ./cfgs/level2_rpl.cf	
	- ./cfgs/level1_rbgp.cf    
	- ./cfgs/level1_rstatic.cf 
	- ./cfgs/level2_hsrp.cf

6. Configuration order (reverse for config removal):
  - pm
  - rpl
  - vrf
  - if
  - hsrp
  - rstatic
  - rbgp

7. Please, report bugs directly to salvatore@cuzzilla.org

#!/bin/bash

if test -r /etc/check_mk/bench.cfg  ; then
    . /etc/check_mk/bench.cfg
else
    echo "keine config gefunden"
fi



#_pingonly=yes
#_livecheck=yes
#_livecheck_helpers=20
#_central=zentrale
#_sites=5
#_hosts=1000
#_pnp=on
#_delay_precompile=False


central=${_central}
pnp=${_pnp}
pingonly=${_pingonly}


setup_apache()
{
if [ -r /etc/redhat-release ]; then
    # most OS don't just blindly enable and start a service.
    chkconfig httpd on
    service   httpd start
    # stop the firewall - i don't know how to carefully punch a hole.
    chkconfig iptables off
    service   iptables stop
fi
}

gen_sites()
{
i=1
while [ ${_sites} -ge $i ]; do
    sites="$sites site${i}" 
    i=$(( $i + 1 ))
done
export sites
}


config_omd_sites()
{

gen_sites
i=0
for site in ${sites} ; do
    i=$(( $i + 1 ))
    omd   stop $site
    echo yes | omd rm $site
    omd create $site
    omd config $site set AUTOSTART off
    omd config $site set PNP4NAGIOS $pnp
    omd config $site set APACHE_MODE shared
    omd config $site set LIVESTATUS_TCP on
    omd config $site set APACHE_TCP_PORT $(( 5000 + $i ))
    omd config $site set LIVESTATUS_TCP_PORT $(( 6557 + $i ))
    # Bug - dont yet listen to livecheck y/n
    echo "broker_module=/omd/sites/${site}/lib/mk-livestatus/livestatus.o livecheck=/omd/versions/default/lib/mk-livestatus/livecheck num_livecheck_helpers=${_livecheck_helpers} num_client_threads=20 pnp_path=/omd/sites/${site}/var/pnp4nagios/perfdata /omd/sites/${site}/tmp/run/live
event_broker_options=-1" > /omd/sites/$site/etc/mk-livestatus/nagios.cfg

done
}


config_omd_central()
{
    if ! omd sites | grep $central 2>&1 > /dev/null ; then
        omd create $central
    fi
    omd   stop $central
    #omd config $central set CORE none
    #omd config $central LIVESTATUS_TCP off      2>/dev/null
}


get_cache()
{

if [ -x `which check_mk_agent` ]; then
    check_mk_agent > /dev/shm/cmk.cache
else
    echo "Check_MK Agent fehlt"
fi

}


prepare()
{
    get_cache
    setup_apache
    config_omd_sites    
    config_omd_central
    chmod u+s /opt/omd/versions/default/lib/mk-livestatus/livecheck
}


setup_central()
{
    echo "all_hosts += [ 'localhost|tcp', ]" > /omd/sites/${central}/etc/check_mk/conf.d/server.mk
    su - $central -c ". .profile && cmk -I"

    siteconfig=/omd/sites/${central}/etc/check_mk/multisite.d/connections.mk
    echo "sites = {"         > $siteconfig
    echo "    \"local\":   {
    \"alias\":        \"Die Zentrale\",
    },"   >> $siteconfig
    i=0
    for site in $sites ; do
        i=$(( $i + 1 ))
        echo "    \"site${i}\":   {
        \"alias\":      \"site${i}\",
        \"socket\":     \"tcp:127.0.0.1:$(( 6557 + $i ))\",
        \"url_prefix\":  \"http://192.168.10.65/site${i}\",
    },"      >> $siteconfig
    done
    echo "}" >> $siteconfig
     
}

start_omds()
{

   for site in $central $sites ; do
       omd start $site
   done

}


add_hosts()
{

for site in $sites ; do

echo "delay_precompile = ${_delay_precompile}" > /omd/sites/$site/etc/check_mk/conf.d/options.mk

 
cat <<EOF > /omd/sites/$site/etc/check_mk/conf.d/hosts.mk
execfile('/etc/check_mk/bench.cfg')
    
    
if _pingonly == "yes":
    _tag = "ping"
else:
    _tag = "tcp"
    
    
_i=0
while _i < _hosts:
    _i = _i + 1
    _hostdef = "dummyhost%d|%s" % (_i, _tag) 
    all_hosts += [ _hostdef ]
    ipaddresses.update(
    {
        "dummyhost%d" % _i : "127.0.0.1" 
    })
EOF

cat <<ZXY > /omd/sites/$site/etc/check_mk/conf.d/service.mk
extra_service_conf["normal_check_interval"] = [ 
#    ( "0.0166", ALL_HOSTS, [ "Dummy" ] ),
    ( "0.0166", ALL_HOSTS, [ "Ping" ] ),
]
legacy_checks += [ 
#    (( "check-mk-vapor", "Dummy", True), ALL_HOSTS), 
    (( "check-mk-ping",  "Ping",  True), ALL_HOSTS), 
]
extra_nagios_conf += r"""
define command {
    command_name check-mk-vapor
    command_line /usr/bin/printf OK
}
"""
ZXY
    
    if [ $pingonly = "no" ]; then
    
cat <<ABC > /omd/sites/$site/etc/check_mk/conf.d/datasources.mk
datasource_programs += [( "cat /dev/shm/cmk.cache", ALL_HOSTS )]
ABC
        
cat <<ZZZ >> /omd/sites/$site/etc/check_mk/conf.d/service.mk
checks += [
          (ALL_HOSTS, "cpu.loads", None, cpuload_default_levels),
          (ALL_HOSTS, "cpu.threads", None, threads_default_levels),
          (ALL_HOSTS, "df", '/', {}),
          (ALL_HOSTS, "df", '/opt', {}),
          (ALL_HOSTS, "diskstat", 'SUMMARY', diskstat_default_levels),
          (ALL_HOSTS, "kernel", 'Context Switches', kernel_default_levels),
          (ALL_HOSTS, "kernel", 'Major Page Faults', kernel_default_levels),
          (ALL_HOSTS, "kernel", 'Process Creations', kernel_default_levels),
          (ALL_HOSTS, "kernel.util", None, kernel_util_default_levels),
          (ALL_HOSTS, "mem.used", None, memused_default_levels),
          (ALL_HOSTS, "mounts", '/', ['data=ordered', 'errors=remount-ro', 'relatime', 'rw']),
          (ALL_HOSTS, "mounts", '/opt', ['attr2', 'noatime', 'nobarrier', 'nodiratime', 'noquota', 'rw']),
          (ALL_HOSTS, "omd_status", 'zentrale', None),
          (ALL_HOSTS, "tcp_conn_stats", None, tcp_conn_stats_default_levels),
          (ALL_HOSTS, "uptime", None, None),
]
ZZZ
        
    fi
    
    su - $site -c ". .profile && rm var/check_mk/autochecks/* 2>/dev/null;  cmk -R"
done

}



prepare         
setup_central
start_omds
add_hosts

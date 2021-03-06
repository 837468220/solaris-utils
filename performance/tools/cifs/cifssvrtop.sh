#!/usr/bin/ksh
#
# cifsvsvrtop - display top CIFS I/O events on a server.
#
# This is measuring the response time between an incoming CIFS operation
# and its response. In general, this measures the server's view of how
# quickly it can respond to requests. By default, the list shows responses
# to each client.
# 	
# Top-level fields:
#   load    1 min load average
#   read    total KB read during sample
#   write   total KB sync writes during sample
#
# The following per-client and "all" clients fields are shown
#   Client  Client IPv4 address or workstation name
#   CIFSOPS CIFS operations per second
#   Reads   Read operations per second
#   Writes  Write operations per second
#   Rd_bw   Read bandwidth KB/sec
#   Wr_bw   Write bandwidth KB/sec
#   Rd_t    Average read time in microseconds
#   Wr_t    Average write time in microseconds
#   Align%  Percentage of read/write operations that have offset aligned to
#           blocksize (default=4096 bytes)
#
# Note: dtrace doesn't do floating point. A seemingly zero response or 
# count can result due to integer division.
# 
#
# INSPIRATION:  top(1) by William LeFebvre and iotop by Brendan Gregg
#
# Copyright 2011, Nexenta Systems, Inc. All rights reserved.
# Copyright 2012, Richard Elling, All rights reserved.
#
# CDDL HEADER START
#
#  The contents of this file are subject to the terms of the
#  Common Development and Distribution License, Version 1.0 only
#  (the "License").  You may not use this file except in compliance
#  with the License.
#
#  You can obtain a copy of the license at Docs/cddl1.txt
#  or http://www.opensolaris.org/os/licensing.
#  See the License for the specific language governing permissions
#  and limitations under the License.
#
# CDDL HEADER END
#
# Author: Richard.Elling@Nexenta.com
#
# Revision:
#   1.9	29-Nov-2012
#
# TODO: share filter
# TODO: IPv6 support
PATH=/usr/sbin:/usr/bin

##############################
# check to see if the NFS server module is loaded
# if not, then the dtrace probes will fail ungracefully
if [ "$(uname -s)" = "SunOS" ]; then
	modinfo | awk '{print $6}' | grep -q smbsrv
	if [ $? != 0 ]; then
		echo "error: SMB server module is not loaded, are you serving SMB (CIFS)?"
		exit 1
	fi
fi

##############################
# --- Process Arguments ---
#

### default variables
opt_blocksize=4096  # blocksize for alignment measurements
opt_client=0        # set if -c option set
opt_clear=1         # set if screen to be cleared
opt_json=0          # set if output is JSON
opt_top=0           # set if list trimmed to top
opt_wsname=0        # set if workstation name desired rather than IPv4 addr
top=0               # number of lines trimmed
interval=10         # default interval
count=-1            # number of intervals to show

### process options
while getopts b:c:Cjt:w name
do
    case $name in
        b)  opt_blocksize=$OPTARG ;;
        c)  opt_client=1; client_ws=$OPTARG ;;
        C)  opt_clear=0 ;;
        j)  opt_json=1 ;;
        t)  opt_top=1; top=$OPTARG ;;
        w)  opt_wsname=1 ;;
        h|?)    cat <<END >&2
USAGE: cifssvrtop [-Cj] [-b blocksize] [-c client_ws] [-t top] 
                 [interval [count]]
             -b blocksize # alignment blocksize (default=4096)
             -c client_ws # trace for this client only
             -C           # don't clear the screen
             -j           # print output in JSON format
             -t top       # print top number of entries only
             -w           # print workstation name instead of IPv4 addr
   examples:
     cifssvrtop         # default output, 10 second samples
     cifssvrtop -b 1024 # check alignment on 1KB boundary
     cifssvrtop 1       # 1 second samples
     cifssvrtop -C 60   # 60 second samples, do not clear screen
     cifssvrtop -t 20   # print top 20 lines only
     cifssvrtop 5 12    # print 12 x 5 second samples
END
        exit 1
    esac
done

shift $(($OPTIND - 1))

### option logic
if [ ! -z "$1" ]; then
    interval=$1; shift
fi
if [ ! -z "$1" ]; then
    count=$1; shift
fi
if [ $opt_clear = 1 ]; then
    clearstr=$(clear)
else
    clearstr=""
fi

#################################
# --- Main Program, DTrace ---
#
/usr/sbin/dtrace -Cn '
/*
 * Command line arguments
 */
inline int OPT_blocksize = '$opt_blocksize';
inline int OPT_clear 	= '$opt_clear';
inline int OPT_client   = '$opt_client';
inline int OPT_top 	= '$opt_top';
inline int OPT_json	= '$opt_json';
inline int OPT_wsname = '$opt_wsname';
inline int INTERVAL 	= '$interval';
inline int COUNTER 	= '$count';
inline int TOP          = '$top';
inline string CLIENT	= "'$client_ws'";
inline string CLEAR 	= "'$clearstr'";

#pragma D option quiet

/* increase dynvarsize if you get "dynamic variable drops" */
#pragma D option dynvarsize=8m

/*
 * Print header
 */
dtrace:::BEGIN 
{
    /* starting values */
    counts = COUNTER;
    secs = INTERVAL;
    total_read_bw = 0;
    total_write_bw = 0;

    printf("Tracing... Please wait.\n");
}

/*
 * Filter as needed, based on starts
 */
sdt:smbsrv::-smb_op-*-start
{
    self->sr = (smb_request_t *)arg0;
    self->ipaddr = inet_ntoa((ipaddr_t *)&self->sr->session->ipaddr);
    self->wsname = stringof(self->sr->session->workstation);
    self->me = OPT_wsname == 0 ? self->ipaddr : self->wsname;
}

sdt:smbsrv::-smb_op-*-start
/self->sr && (OPT_client == 0 || CLIENT == self->me)/
{ 
    @c_cifsops[self->me] = count();
    OPT_client == 0 ? @c_cifsops["all"] = count() : 1;
}

sdt:smbsrv::-smb_op-ReadX-start,
sdt:smbsrv::-smb_op-ReadRaw-start,
sdt:smbsrv::-smb_op-Read-start,
sdt:smbsrv::-smb_op-WriteX-start,
sdt:smbsrv::-smb_op-WriteRaw-start,
sdt:smbsrv::-smb_op-Write-start
/self->sr && (OPT_client == 0 || CLIENT == self->me)/
{ 
    self->startts = timestamp;
}

/*
 * read
 */
sdt:smbsrv::-smb_op-ReadX-start,
sdt:smbsrv::-smb_op-ReadRaw-start,
sdt:smbsrv::-smb_op-Read-start
/self->startts/
{
    self->rwp = (smb_rw_param_t *)arg1;
    @c_read[self->me] = count();
    OPT_client == 0 ? @c_read["all"] = count() : 1;
    @read_bw[self->me] = sum(self->rwp->rw_count);
    OPT_client == 0 ? @read_bw["all"] = sum(self->rwp->rw_count) : 1;
    total_read_bw += self->rwp->rw_count;
    @avg_aligned[self->me] = 
        avg((self->rwp->rw_offset % OPT_blocksize) ? 0 : 100);
    @avg_aligned["all"] = 
        avg((self->rwp->rw_offset % OPT_blocksize) ? 0 : 100);
}

sdt:smbsrv::-smb_op-ReadX-done,
sdt:smbsrv::-smb_op-ReadRaw-done,
sdt:smbsrv::-smb_op-Read-done
/self->startts && self->sr/
{
    t = timestamp - self->startts;
    @avgtime_read[self->me] = avg(t);
    OPT_client == 0 ? @avgtime_read["all"] = avg(t) : 1;
    self->startts = 0;
}

/*
 * write
 */
sdt:smbsrv::-smb_op-WriteX-start,
sdt:smbsrv::-smb_op-WriteRaw-start,
sdt:smbsrv::-smb_op-Write-start
/self->startts && self->sr/
{
    self->rwp = (smb_rw_param_t *)arg1;
    @c_write[self->me] = count();
    OPT_client == 0 ? @c_write["all"] = count() : 1;
    @write_bw[self->me] = sum(self->rwp->rw_count);
    OPT_client == 0 ? @write_bw["all"] = sum(self->rwp->rw_count) : 1;
    total_write_bw += self->rwp->rw_count;
    @avg_aligned[self->me] = 
        avg((self->rwp->rw_offset % OPT_blocksize) ? 0 : 100);
    @avg_aligned["all"] = 
        avg((self->rwp->rw_offset % OPT_blocksize) ? 0 : 100);
}

sdt:smbsrv::-smb_op-WriteX-done,
sdt:smbsrv::-smb_op-WriteRaw-done,
sdt:smbsrv::-smb_op-Write-done
/self->startts && self->sr/
{
	t = timestamp - self->startts;
	@avgtime_write[self->me] = avg(t);
	OPT_client == 0 ? @avgtime_write["all"] = avg(t) : 1;
	self->startts = 0;
}

/*
 * timer
 */
profile:::tick-1sec
{
	secs--;
}

/*
 * Print report
 */
profile:::tick-1sec
/secs == 0/
{	
    /* fetch 1 min load average */
    self->load1a = `hp_avenrun[0] / 65536;
    self->load1b = ((`hp_avenrun[0] % 65536) * 100) / 65536;

    /* convert counters to Kbytes */
    total_read_bw /= 1024;
    total_write_bw /= 1024;

    /* normalize to seconds giving a rate */
    /* todo: this should be measured, not based on the INTERVAL */
    normalize(@c_cifsops, INTERVAL);
    normalize(@c_read, INTERVAL);
    normalize(@c_write, INTERVAL);

    /* normalize to KB per second */
    normalize(@read_bw, 1024 * INTERVAL);
    normalize(@write_bw, 1024 * INTERVAL);

    /* normalize average to microseconds */
    normalize(@avgtime_read, 1000);
    normalize(@avgtime_write, 1000);

    /* print status */
    OPT_clear && !OPT_json ? printf("%s", CLEAR) : 1;

    OPT_json ? 
        printf("{ \"collector\": \"cifssvrtop\", \"time\": \"%Y\", \"timestamp\": %d, \"interval\": %d, \"load\": %d.%02d, \"read_KB_int\": %d, \"write_KB_int\": %d, \"clientdata\": [",
            walltimestamp, walltimestamp, INTERVAL, 
            self->load1a, self->load1b, 
            total_read_bw, total_write_bw)
    :
        printf("%Y, load: %d.%02d, read: %-8d KB, write: %-8d KB\n",
            walltimestamp, self->load1a, self->load1b, 
            total_read_bw, total_write_bw);

    /* print headers */
    OPT_json ? 1 :
        printf("%-15s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\n",
            "Client", "CIFSOPS", 
            "Reads", "Writes", "Rd_bw", "Wr_bw", "Rd_t", "Wr_t", "Align%");

    /* truncate to top lines if needed */
    OPT_top ? trunc(@c_cifsops, TOP) : 1;

    OPT_json ?
        printa("{\"client\": \"%s\", \"CIFSOPS\": %@d, \"reads\": %@d, \"writes\": %@d, \"read_bw\": %@d, \"write_bw\": %@d, \"avg_read_t\": %@d, \"avg_write_t\": %@d, \"aligned_pct\": %@d },",
            @c_cifsops, @c_read, @c_write, @read_bw, @write_bw,
            @avgtime_read, @avgtime_write, @avg_aligned)
    :
        printa("%-15s\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\n",
            @c_cifsops, @c_read, @c_write, @read_bw, @write_bw,
            @avgtime_read, @avgtime_write, @avg_aligned);

    OPT_json ? printf("{}]}\n") : 1;

    /* clear data */
    trunc(@c_cifsops); trunc(@c_read); trunc(@c_write); 
    trunc(@read_bw); trunc(@write_bw); 
    trunc(@avgtime_read); trunc(@avgtime_write);
    trunc(@avg_aligned);
    total_read_bw = 0;
    total_write_bw = 0;
    secs = INTERVAL;
    counts--;
}

/*
 * end of program 
 */
profile:::tick-1sec
/counts == 0/
{
	exit(0);
}

/*
 * clean up when interrupted
 */
dtrace:::END
{
    trunc(@c_cifsops); trunc(@c_read); trunc(@c_write); 
    trunc(@read_bw); trunc(@write_bw); 
    trunc(@avgtime_read); trunc(@avgtime_write);
    trunc(@avg_aligned);
}
'
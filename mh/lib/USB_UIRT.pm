
=begin comment

USB_UIRT.pm - Misterhouse interface for the USB-UIRT infrared receiver and transmitter

Info available at: http://home.earthlink.net/~jrhees/USBUIRT/index.htm

03/26/2003	Created by David Norwood (dnorwood2@yahoo.com)
10/15/2003  Brian G. Ujvary and David Norwood added support for the Windows DLL driver


To enable this module, add these entries to your .ini file:

usb_uirt_module=USB_UIRT
usb_uirt_port=/dev/ttyUSB1	# optional, defaults to /dev/ttyUSB0, not used on Windows

Transmitting

Use the web interface generated by USB_UIRT_learning.pl to learn and import codes.  Then create
your own code file that uses IR_Item to transmit.

$TV  = new IR_Item 'TV', 'addEnter', 'usb_uirt';

my $tv_states = 'power,mute,vol+,vol-,ch+,ch-,2,3,4,5,6,7,8,9,11,13,14';

set_states $TV split ',', $tv_states if $Reload;
$v_tv_control = new  Voice_Cmd("tv [$tv_states]");

if (($state = said $v_tv_control)) {
    print_log "Setting TV to $state";
    set $TV $state;
}

Receiving

This module will report incoming infrared signals in the Misterhouse log output.  You can use
these signal codes to create triggers that can control your MP3 player, DVD software, etc.
To use this feature, add lines like these to your code:

$remote = new Serial_Item '190003A0A0E2', 'play';
 $remote->add              '190003AEB012', 'stop';

if (my $state = state_now $remote) {
    set $mp3 $state;
}

Wake on USB

not implemented

=cut

use strict;

package USB_UIRT;

@USB_UIRT::ISA = ('Serial_Item');

my $prev = '';
my $learning = 0;
my $dbm_file ="$main::config_parms{data_dir}/usb_uirt_codes.dbm";
my ($db, %DBM, @learned, $device, $function, $frequency, $repeat, @transmit_queue, @learn_queue, @learn_frequencies, $transmit_timeout, $learn_timeout, $receive_timeout);
my ($DrvHandle);

use constant UUIRTDRV_CFG_LEDRX    => 0x01;	# Indicator LED on USB-UIRT blinks when remote signals are received
use constant UUIRTDRV_CFG_LEDTX    => 0x02;	# Indicator LED on USB-UIRT lights during IR transmission
use constant UUIRTDRV_CFG_LEGACYRX => 0x04;	# Generate 'legacy' UIRT-compatible codes on receive

use constant UUIRTDRV_IRFMT_UUIRT  => 0x0000;
use constant UUIRTDRV_IRFMT_PRONTO => 0x0010;

use constant UUIRTDRV_IRFMT_LEARN_FORCERAW   => 0x0100;
use constant UUIRTDRV_IRFMT_LEARN_FORCESTRUC => 0x0200;
use constant UUIRTDRV_IRFMT_LEARN_FORCEFREQ  => 0x0400;
use constant UUIRTDRV_IRFMT_LEARN_FREQDETECT => 0x0800;

use constant UUIRTDRV_ERR_NO_DEVICE => 0x20000001;
use constant UUIRTDRV_ERR_NO_RESP   => 0x20000002;
use constant UUIRTDRV_ERR_NO_DLL    => 0x20000003;
use constant UUIRTDRV_ERR_VERSION   => 0x20000004;

if ($^O eq 'MSWin32') {

	Win32::API::Type->typedef('HUUHANDLE', 'PHANDLE');

	Win32::API::Struct->typedef( 'UUINFO', qw(
		UINT fwVersion;
		UINT protVersion;
		UCHAR fwDateDay;
		UCHAR fwDateMonth;
		UCHAR fwDateYear;
	));

	sub PrintError {
		my $errno = Win32::GetLastError();
		my $errstr = Win32::FormatMessage($errno);
		printf("\n\t*** ERROR: errno=%d, %s", $errno, $errstr);
	}

	# UUIRTDRV_API BOOL PASCAL UUIRTGetDrvInfo(unsigned int *puDrvVersion);
	Win32::API->Import('uuirtdrv', 'BOOL UUIRTGetDrvInfo(PUINT puDrvVersion)');

	# UUIRTDRV_API HUUHANDLE PASCAL UUIRTOpen(void);
	Win32::API->Import('uuirtdrv', 'HUUHANDLE  UUIRTOpen()');

	# UUIRTDRV_API BOOL PASCAL UUIRTGetUUIRTInfo(HUUHANDLE hHandle, PUUINFO *puuInfo);
	Win32::API->Import('uuirtdrv', 'BOOL UUIRTGetUUIRTInfo(HUUHANDLE hHandle, LPUUINFO lppuuInfo)');

	# UUIRTDRV_API BOOL PASCAL UUIRTGetUUIRTConfig(HUUHANDLE hHandle, PUINT32 pUirtConfig);
	Win32::API->Import('uuirtdrv', 'BOOL UUIRTGetUUIRTConfig(HUUHANDLE hHandle, PUINT pUirtConfig)');

	# UUIRTDRV_API BOOL PASCAL UUIRTTransmitIR(HUUHANDLE hHandle, char *IRCode, int codeFormat, int repeatCount,
	#					 int inactivityWaitTime, HANDLE hEvent, void *reserved0, void *reserved1);
	Win32::API->Import('uuirtdrv', 'BOOL UUIRTTransmitIR(HUUHANDLE hHandle, PCHAR IRCode, INT codeFormat, INT repeatCount,
			 INT inactivityWaitTime, HANDLE hEvent, PVOID reserved0, PVOID reserved1)');

	# UUIRTDRV_API BOOL PASCAL UUIRTClose(HUUHANDLE hHandle);
	Win32::API->Import('uuirtdrv', 'BOOL UUIRTClose(HUUHANDLE hHandle)');
}

END {if ($^O eq 'MSWin32') {UUIRTClose($DrvHandle);}}

sub startup {
	&::MainLoop_pre_add_hook(  \&USB_UIRT::check_for_data, 1 );
	$db = tie (%DBM,  'DB_File', $dbm_file) or print "\nError, can not open dbm file $dbm_file: $!";
	if ($^O eq 'MSWin32') {
		print "Quering USB-UIRT device driver information...\n";
		my $DrvVersion;
		if (UUIRTGetDrvInfo($DrvVersion)) {
			printf("** USB-UIRT Driver Info: 0x%04x\n\n", $DrvVersion);
		} else {
			PrintError();
		}

		print "\nOpening communication with the USB-UIRT device...\n";
		$DrvHandle = UUIRTOpen();
		if ($DrvHandle eq -1) {
			PrintError();
		} else {
			print "...opened communication with the USB-UIRT device.\n";
		}
	} else {
		my $baudrate = 38400;		# this is arbitrary, Linux overrides it, Windows uses DLL
		my $port = '/dev/ttyUSB0';
		$port = $main::config_parms{usb_uirt_port} if $main::config_parms{usb_uirt_port};
		&main::serial_port_create('USB_UIRT', $port, $baudrate, 'none', 'raw');
		select undef, undef, undef, .05;
		&main::check_for_generic_serial_data('USB_UIRT');
		my $data = $main::Serial_Ports{USB_UIRT}{data};
		$main::Serial_Ports{USB_UIRT}{data} = '';
	}
	get_version();
	get_config();
}

sub check_for_data {
	my ($self) = @_;
	if ($learning and &main::get_tickcount - $learn_timeout > 0) {
		save_code();
	}
	elsif (&main::get_tickcount - $receive_timeout > 0) {
		$prev = '';
	}
	if(@transmit_queue) {
		print "got here \n";
		send_ir_code();
	}
	return if $^O eq 'MSWin32';
	&main::check_for_generic_serial_data('USB_UIRT');
	my $data = $main::Serial_Ports{USB_UIRT}{data};
	$main::Serial_Ports{USB_UIRT}{data} = '';
	return unless $data;

	if($learning) {
		process_raw($data);
	}
	else {
		receive_code($data);
	}

}

sub receive_code {
	my $data = shift;
	my @bytes = unpack 'C6', $data;
	my $code = uc unpack 'H*', pack 'C*', @bytes;
	return if $code eq $prev;
	$prev = $code;
	$receive_timeout = &main::get_tickcount + 600;

	&main::main::print_log("USB_UIRT Code: $code");
	&main::process_serial_data($code);
}

sub learn_code {
	$device = uc shift;
	$function = uc shift;
	$frequency = shift;
	$repeat = shift;
	return unless $device and $function;
	$DBM{"$device$;$function"} = 0;
	set_moderaw();
	$learning = 1;
	$learn_timeout = &main::get_tickcount + 60000;
	@learned = ();
}

sub save_code {
	set_modeuir();
	$learning = 0;
	unless (@learned) {
		print "USB_UIRT: Learning function timed out\n";
		return;
	}
	my (@code1, @code2);
	foreach my $code (@learned) {

		if ((! @code1) or raw_match($code1[0], $code)) {
			push @code1, $code;
		}
		elsif ((! @code2) or raw_match($code2[0], $code)) {
			push @code2, $code;
		}
		else {
			print "USB_UIRT: Learning error, received more than two different codes \n";
		}
	}
	set_ir_code($device, $function,
		learnraw_to_pronto(frequency_average(), $repeat, raw_average(@code1), raw_average(@code2)));
	print "USB_UIRT: Saved device $device function $function \n";
}

sub raw_match {
	my @bytes1 = unpack 'C*', pack 'H*', shift;
	my @bytes2 = unpack 'C*', pack 'H*', shift;
	return 0 unless @bytes1 == @bytes2;
	shift @bytes1; shift @bytes1;
	shift @bytes2; shift @bytes2;
	my $i = 0;
	foreach (@bytes1) {
		return 0 if abs($_ - $bytes2[$i]) > 2;
		$i++;
	}
	return 1;
}

sub frequency_average {
	return 40 unless @learn_frequencies;
	my $sum;
	foreach (@learn_frequencies) {
		$sum += $_;
	}
	return $sum / @learn_frequencies;
}

sub raw_average {
	return unless my $i = @_;
	return shift if $i == 1;
	my @sums;
	my $inter;
	foreach (@_) {
		my @words = unpack 'n*', pack 'H*', $_;
		$inter = shift @words;
		my $j = 0;
		foreach (@words) {
			$sums[$j] += $_;
			$j++;
		}
	}
	map {$_ /= $i} @sums;
	@sums[$#sums] = $inter;
	my $code = unpack 'H*', pack 'n*', @sums;
	return $code;
}

sub set {
	$device = uc shift;
	$function = uc shift;
	return unless defined $device and defined $function;
      push @transmit_queue, "$device$;$function";
}

sub send_ir_code {
	return if &main::get_tickcount - $transmit_timeout < 0;
	my $code = $DBM{shift @transmit_queue};
	if ($code =~ s/^R//i) {
		transmit_raw($code);
	}
	elsif ($code =~ s/^P(..) //i) {
		my $repeat = $1;
		$repeat = unpack 'c', pack 'H2', $repeat;
		transmit_pronto($code, $repeat);
	}
	else {
		transmit_struct($code);
	}
}

sub process_raw {
	my $data = shift;
 	my $pos = index $data, "\xFFFF";
my $db = unpack 'H*', pack 'C*', $data ;
print "Pos $pos data $db\n";
	my ($code, $remainder);
	$remainder = substr $data, $pos + 3 unless $pos == -1 or $pos + 3 == length $data;
	$remainder = $data if $pos == -1;
	$main::Serial_Ports{USB_UIRT}{data} = $remainder;
	print "USB_UIRT: rec length " . length($code) . " code $code\n";
	return unless $pos > 4;
	my @bytes = unpack 'C*', substr $data, 0, $pos + 1;
	$code = unpack 'H4', pack 'C2', splice @bytes, 0, 2;
	while (@bytes > 4) {
		my $pulse = $bytes[0] * 256 + $bytes[1];
		$code .= unpack 'H4', pack 'C2', splice @bytes, 0, 2;
		my $count = shift @bytes;
		$count = ($count & 0x7f) << 8 | shift @bytes if ($count & 0x80);
		my $frequency = (1000000 / (($pulse * 0.4) / ($count - 0.5)));
		push @learn_frequencies, $frequency if $count;
		if (@bytes < 2) {
			print "USB_UIRT: Oops, not enough bytes at end of learn sequence \n";
			return;
		}
		$code .= unpack 'H4', pack 'C2', splice @bytes, 0, 2;
	}
	if (@bytes) {
		print "USB_UIRT: Oops, extra bytes at end of learn sequence \n";
		return;
	}
	push @learned, $code;
	$learn_timeout = &main::get_tickcount + 2000;
}


sub get_version {
    my ($firmware_minor, $firmware_major, $protocol_minor, $protocol_major, $firmware_day, $firmware_month, $firmware_year);
    print "\nGetting UIRT Info...\n";
    if ($^O eq 'MSWin32') {
        my $UirtInfo = Win32::API::Struct->new('UUINFO');
        if (UUIRTGetUUIRTInfo($DrvHandle, $UirtInfo)) {
            $firmware_major = $UirtInfo->{fwVersion}>>8;
            $firmware_minor = $UirtInfo->{fwVersion}&0xff;
            $protocol_major = $UirtInfo->{protVersion}>>8;
            $protocol_minor = $UirtInfo->{protVersion}&0xff;
            $firmware_month = $UirtInfo->{fwDateMonth};
            $firmware_day = $UirtInfo->{fwDateDay};
            $firmware_year = $UirtInfo->{fwDateYear};        # Bruce update this line for correct display on win32 platforms
        } else {
	    PrintError();
        }
    } else {
	usb_uirt_send(0x23);
	my $ret = get_response(8);
    printf("USB_UIRT: get_version returned 0x%X\n",$ret) unless ($ret == 0x21);
	($firmware_minor, $firmware_major, $protocol_minor, $protocol_major, $firmware_day, $firmware_month, $firmware_year)
	    = unpack 'C*', $ret;
    }
    printf "USB_UIRT Protocol Version %d.%d\n", $protocol_major, $protocol_minor;
    printf "USB_UIRT Firmware Version %d.%d  Date %02d/%02d/20%02d\n",
          $firmware_major, $firmware_minor, $firmware_month, $firmware_day, $firmware_year;
}

sub get_config {
	print "\nGetting UIRT Config Info...\n";
	my $UirtConfig;
	if ($^O eq 'MSWin32') {
		if (UUIRTGetUUIRTConfig($DrvHandle, $UirtConfig)) {
		} else {
			PrintError();
		}
	} else {
		usb_uirt_send(0x38, 1);
		my $ret = get_response(3);
        printf("USB_UIRT: get_config returned 0x%X\n",$ret) unless ($ret == 0x21);
		($UirtConfig) = unpack 'C', $ret;
	}
	print "** USB-UIRT Config: ";
	printf("currently = %08X (LED_RX=%d, LED_TX=%d, LEGACY_RX=%d)\n",
		$UirtConfig,
		$UirtConfig & UUIRTDRV_CFG_LEDRX ? 1 : 0,
		$UirtConfig & UUIRTDRV_CFG_LEDTX ? 1 : 0,
		$UirtConfig & UUIRTDRV_CFG_LEGACYRX ? 1 : 0);
}

sub set_moderaw {
	$learning = 1;
	@learned = ();
	usb_uirt_send(0x24);
	my $ret = get_response(1);
    printf("USB_UIRT: get_moderaw returned 0x%X\n",$ret) unless ($ret == 0x21);
}

sub set_modeuir {
	$learning = 0;
	usb_uirt_send(0x20);
	my $ret = get_response(1);
}

sub get_response {
	my $length = shift;
	select undef, undef, undef, .05;
	my ($count, $ret) = $main::Serial_Ports{USB_UIRT}{object}->read($length);
	print  "USB_UIRT expected $length byte response, only got $count \n" unless $count == $length;
	return $ret;
}

sub transmit_raw {
 	my @bytes = unpack('C*', pack 'H*', shift);
	splice @bytes, 4, 0, $#bytes - 3;
	$transmit_timeout = &main::get_tickcount + 500;
#	my $t = 0.10;
#	foreach (@bytes) {$t += $_}
	usb_uirt_send(0x36, $#bytes + 2, @bytes);
	my $ret = get_response(1);
    printf("USB_UIRT: transmit_raw returned 0x%X\n",$ret) unless ($ret == 0x21);
}

sub transmit_pronto {
	my $pronto = shift;
	my $repeat = shift;
	$pronto =~ s/[^0-9a-fA-F ]//gs;
	if ($^O eq 'MSWin32') {
		print "\nTransmitting repeat $repeat code $pronto via USB-UIRT device...\n";
		my ($reserved0, $reserved1);
		my $IRCodeFormat = UUIRTDRV_IRFMT_PRONTO;
		if (!UUIRTTransmitIR($DrvHandle, $pronto, $IRCodeFormat, $repeat, 0, 0, $reserved0, $reserved1)) {
			printf("\n\t*** ERROR calling UUIRTTransmitIR! ***");
			PrintError;
		}
		else {
			print("...IR Transmission Complete!\n");
		}
		$transmit_timeout = &main::get_tickcount + 500;
		return;
	}
	$pronto =~ s/ //g;
	my @bytes = unpack 'n*', pack 'H*', $pronto;
	my $kind = shift @bytes;
	my $units = shift(@bytes) * .241246;
	my $frequency = round(2.5 * $units);
	my $first = shift(@bytes) * 2;
	my $second = shift(@bytes) * 2;
	my $both;
	$both = 1 if $first and $second;
	foreach my $length ($first, $second) {
		next unless $length;
		my @raw;
		push @raw, $frequency;
		push @raw, $both ? 1 : $repeat;
		push @raw, 0, 0;
#		push @raw, ($bytes[$length - 1] >> 8) * $units / 51.2, ($bytes[$length - 1] & 0xff) * $units / 51.2;
#		$length--;
		while ($length > 0) {
			my $word = shift @bytes;
			if ($word > 0x7f) {
				push @raw, ($word >> 8) | 0x80;
			}
   			push @raw, $word & 0xff;
			$length--;
		}
		splice @raw, 4, 0, $#raw - 3;
		usb_uirt_send(0x36, $#raw + 2, @raw);
		if ($both) {
			my ($count, $ret, $giveup);
			until ($count > 0 or $giveup > 2000) {
				($count, $ret) = $main::Serial_Ports{USB_UIRT}{object}->read(1);
				$giveup++;
			}
			$both = 0;
		}
	}
	$transmit_timeout = &main::get_tickcount + 500;
	my $ret = get_response(1);
    printf("USB_UIRT: transmit_pronto returned 0x%X\n",$ret) unless ($ret == 0x21);
}

sub transmit_struct {
 	my @bytes = unpack('C*', pack 'H*', shift);
	$transmit_timeout = &main::get_tickcount + 500;
	usb_uirt_send(0x37, $#bytes + 2, @bytes);
	my $ret = get_response(1);
    printf("USB_UIRT: transmit_struct returned 0x%X\n",$ret) unless ($ret == 0x21);
}

sub usb_uirt_send {
	my @bytes = @_;

	my $hex = '';
	my $string = '';
	my $checksum = 0;
	foreach (@bytes) {
		$hex .= sprintf '%02x', $_;
		$string .= $_;
		$checksum += $_;
	}
	$checksum = ~$checksum;
	$checksum++;
	$checksum &= 0xff;
	push @bytes, $checksum;
	$hex .= sprintf '%02x', $checksum;
	print "USB_UIRT sending $hex\n";
	$main::Serial_Ports{USB_UIRT}{object}->write(pack 'C*', @bytes);
}

sub raw_to_struct {
	my $frequency = shift;
	my $repeat = shift;
	my $code1 = shift;
	my $code2 = shift;
	my $second = 0;
	foreach ($code1, $code2) {
		next unless $_;
		my @bytes = unpack 'C*', pack 'H*', $_;
		my @struct;
		push @struct, (@bytes[0,1], @bytes - 4, @bytes[2,3]);
		my $bits = '';
		my %sums;
		my $small_pulse = 255;
		my $small_gap = 255;
		my $big_pulse = 0;
		my $big_gap = 0;
		my $i = 0;
		foreach (@bytes[4 .. $#bytes - 1]) {
			($i & 1 ? $small_gap : $small_pulse) = $_ if $_ < ($i & 1 ? $small_gap : $small_pulse);
			($i & 1 ? $big_gap : $big_pulse) = $_ if $_ > ($i & 1 ? $big_gap : $big_pulse);
			$i++;
		}
		print "raw_to_struct code $_\nsmall_gap : $small_gap  small_pulse : $small_pulse big_gap : $big_gap  big_pulse : $big_pulse \n";
		$i = 0;
		foreach (@bytes[4 .. $#bytes - 1]) {
			my $bit = ($_ > 1.5 * ($i & 1 ? $small_gap : $small_pulse)) ? '1' : '0';
			$bits .= $bit;
			push @{ $sums{ ($i & 1 ? ($bit ? 'off1' : 'off0') : ($bit ? 'on1' : 'on0')) }}, $_;
			$i++;
		}
		foreach ('off0', 'off1', 'on0', 'on1') {
			my $sum = 0;
			foreach (@{ $sums{$_} }) {
				$sum += $_;
			}
			push @struct, $sum ? ($sum / ($#{ $sums{$_} } + 1)) : 0;
		}
		push @struct, unpack('C*', pack(($second ? 'b96' : 'b128'), $bits));
		$second++;
		$_ = unpack 'H*', pack 'C*', @struct;
	}
	return ($frequency, $repeat, $code1, $code2);
}

sub struct_to_raw {
	my $frequency = shift;
	my $repeat = shift;
	my $code1 = shift;
	my $code2 = shift;
	return ($frequency, $repeat, $code1, $code2) if ($code1 =~ /^R/i);
	foreach ($code1, $code2) {
		next unless $_;
		my @bytes = unpack 'C*', pack 'H*', $_;
		my @raw;
		push @raw, shift @bytes;
		push @raw, shift @bytes;
		my $length = shift @bytes;
		push @raw, shift @bytes;
		push @raw, shift @bytes;
		my $small_gap = shift @bytes;
		my $big_gap = shift @bytes;
		my $small_pulse = shift @bytes;
		my $big_pulse = shift @bytes;
		my $i = 0;
		foreach (split '', unpack "b$length", pack 'C*', @bytes) {
			$_ += 0;
			push @raw, ($i % 2 ? ($_ ? $big_gap : $small_gap) : ($_ ? $big_pulse : $small_pulse));
			$i++;
		}
		pop @raw unless @raw % 2;
		push @raw, 0xff;
		$_ = unpack 'H*', pack 'C*', @raw;
	}
	return ($frequency, $repeat, $code1, $code2);
}

sub pronto_to_raw {
	my $pronto = shift;
	my $repeat = shift;
	$pronto =~ s/[^0-9a-fA-F]//gs;
	my @bytes = unpack 'n*', pack 'H*', $pronto;
	my $kind = shift @bytes;
	my $units = shift(@bytes) * .241246;
	my $frequency = ($kind == 0 && $units != 0.0) ? round(1000.0/$units) : 0;
	my $first = shift(@bytes) * 2;
	my $second = shift(@bytes) * 2;
	map {$_ = round($_ / 2)} @bytes;
	print "pronto_to_raw $pronto First $first second $second frequency  " . $frequency . "\n";
	my ($code1, $code2);
	$code1 = unpack 'H*', pack('C*', $bytes[$first - 1] >> 8, $bytes[$first - 1] & 0xff,
		@bytes[0 .. $first - 2], 0xff) if $first;
	$code2 = unpack 'H*', pack('C*', $bytes[$first + $second - 1] >> 8, $bytes[$first + $second - 1] & 0xff,
		@bytes[$first .. $first + $second - 2], 0xff) if $second;
	return ($frequency, $repeat, $code1, $code2);
}

sub learnraw_to_pronto {
	my $frequency = shift;
	my $repeat = shift;
	my $code1 = shift;
	my $code2 = shift;
	return unless $code1 or $code2;
	my @words;
	push @words, 0;
	my $units = $frequency ? 1000.0/$frequency : 0;
	push @words, $units ? round($units/.241246) : 0;
	push @words, $code1 ? length($code1)/8 : 0;
	push @words, $code2 ? length($code2)/8 : 0;
	foreach ($code1, $code2) {
		next unless $_;
		my @raw = unpack 'n*', pack 'H*', $_;
		push @words, map {$_ *= 400 * $units} @raw;
	}
	my $code = join(" ", map { sprintf "%04x", $_ } @words);
	return ($code, $repeat);
}

sub raw_to_pronto {
	my $frequency = shift;
	my $repeat = shift;
	my $code1 = shift;
	my $code2 = shift;
	return unless $code1 or $code2;
	my @bytes;
	push @bytes, 0;
	my $units = $frequency ? 1000.0/$frequency : 0;
	push @bytes, $units ? round($units/.241246) : 0;
	if ($code1 =~ s/^R//i) {
					# this is the new usb-uirt raw format without a count
		my @raw = unpack 'C*', pack 'H*', $code1;
		my $inter = (shift @raw) * 256 + shift @raw;
		$inter = round($inter * 51.2/$units);
		my $count;
		while (my $byte = shift @raw) {
			push @bytes, ($byte & 0x80) ? ($byte & 0x7f) << 8 | shift @raw : $byte;
			$count++;
		}
		push @bytes, $inter;
		splice @bytes, 2, 0, round($count/2), 0;
	}
	else {
					# this is just an exploded version of struct
		push @bytes, $code1 ? length($code1)/4 - 1 : 0;
		push @bytes, $code2 ? length($code2)/4 - 1 : 0;
		foreach ($code1, $code2) {
			next unless $_;
			my @raw = unpack 'C*', pack 'H*', $_;
			my $inter = (shift @raw) * 256 + shift @raw;
			pop @raw;
			push @raw, $inter;
			push @bytes, map {$_ *= 2} @raw;
		}
	}
	my $code = join(" ", map { sprintf "%04x", $_ } @bytes);
	return ($code, $repeat);
}

sub list_devices {
	my @devices;
	my $prev = '';
	foreach (sort keys %DBM) {
		my ($device) = split $;;
		push @devices, $device unless $device eq $prev;
		$prev = $device;
	}
	return @devices;
}

sub list_functions {
	my $dev = uc shift;
	my @functions;
	foreach (sort keys %DBM) {
		my ($device, $function) = split $;;
		push @functions, $function if $device eq $dev and $function ne '_dummy_';
	}
	return @functions;
}

sub add_device {
	my $dev = uc shift;
	$DBM{"$dev$;_dummy_"} = 0;
	$db->sync;
}

sub delete_device {
	my $dev = shift;
	foreach (sort keys %DBM) {
		my ($device, $function) = split $;;
		delete $DBM{$_} if $device eq $dev;
	}
	$db->sync;
}

sub rename_device {
	my $dev = shift;
	my $devnew = uc shift;
	return if $dev eq $devnew;
	foreach (sort keys %DBM) {
		my ($device, $function) = split $;;
		$DBM{"$devnew$;$function"} = $DBM{$_} if $device eq $dev;
		delete $DBM{$_} if $device eq $dev;
	}
	$db->sync;
}

sub delete_function {
	my $device = shift;
	my $function = shift;
	delete $DBM{"$device$;$function"};
	$db->sync;
}

sub set_ir_code {
	my $device = uc shift;
	my $function = uc shift;
	my $frequency = shift;
	my $repeat = shift;
	my $code1 = shift;
	my $code2 = shift;
	my $code;
	if ($code1 =~ s/^R//i) {
		$frequency = 40 unless $frequency;
		$frequency = round(2500 / $frequency);
		$code = 'R' . (unpack 'H4', pack 'CC', $frequency, $repeat) . $code1;
	}
	elsif ($code1 =~ /^0000 /) {
		$code1 =~ s/[^0-9a-f ]//igs;
		if ($frequency =~ /\d+/ and $frequency != 0) {
			$frequency = sprintf "%04x", round((1000/$frequency)/.241246);
			$code1 =~ s/^0000 [0-9a-f](4) /0000 $frequency /;
		}
		$code = sprintf "P%02x %s", $repeat, $code1;
	}
	else {
		$frequency = 40 unless $frequency;
		$frequency = round(2500 / $frequency);
		$code = (unpack 'H4', pack 'CC', $frequency, ($code2 ? 0 : $repeat)) . $code1 if $code1;
		$code .= (unpack 'H2', pack 'C', $repeat) . $code2 if $code2;
	}
	$DBM{"$device$;$function"} = $code;
	$db->sync;
}

sub get_ir_code {
	my $device = uc shift;
	my $function = uc shift;
	my ($frequency1, $repeat1, $code1, $frequency2, $repeat2, $code2);
	my $code = $DBM{"$device$;$function"};
	if ($code =~ s/^R//i) {
		($frequency1, $repeat1, $code1) = unpack 'a2a2a*', $code;
		$code1 = 'R' . $code1;
		$frequency1 = unpack 'C', pack 'H2', $frequency1;
		$frequency1 = $frequency1 ? round(2500 / $frequency1) : 0;
		$repeat1 = unpack 'C', pack 'H2', $repeat1;
		$repeat2 = unpack 'C', pack 'H2', $repeat2;
	}
	elsif ($code =~ /^P/i) {
#		print "db get $code\n";
#		($repeat1, $code1, $frequency1) = $code =~ /^P([0-9a-f](2)) (0000 ([0-9a-f](4)) .*)/;
		($repeat1, $frequency1) = unpack 'xa2x6a4', $code;
		$code1 = $code;
		$code1 =~ s/^P...//i;
		$frequency1 = unpack 'n', pack 'H4', $frequency1;
		my $units = $frequency1 * .241246;
		$frequency1 = ($units != 0) ? round(1000.0/$units) : 0;
		$repeat1 = unpack 'c', pack 'H2', $repeat1;
	}
	else {
		($frequency1, $repeat1, $code1, $repeat2, $code2) = unpack 'a2a2a50a2a42', $code;
		$frequency1 = unpack 'C', pack 'H2', $frequency1;
		$frequency1 = $frequency1 ? round(2500 / $frequency1) : 0;
		$repeat1 = unpack 'C', pack 'H2', $repeat1;
		$repeat2 = unpack 'C', pack 'H2', $repeat2;
	}
#	print "db f=$frequency1 c=$code1\n";
	return ($frequency1, $code2 ? $repeat2 : $repeat1, uc $code1, uc $code2);
}

sub rename_function {
	my $device = uc shift;
	my $function = uc shift;
	my $funcnew = uc shift;
	return if $function eq $funcnew;
	return unless $funcnew;
	$DBM{"$device$;$funcnew"} = $DBM{"$device$;$function"};
	delete $DBM{"$device$;$function"};
	$db->sync;
}

sub is_learning {
	return $learning;
}

sub last_learned {
	my $raw;
	foreach (@learned) {
		$raw .= $_ . "\n";
	}
	return $raw;
}

sub round {
	return int shift() + .5;
}

1;

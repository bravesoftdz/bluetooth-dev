program BluetoothTest;
{$mode objfpc}{$modeswitch advancedrecords}{$H+}

{$define USE_WEB_STATUS}

uses 
{$ifdef BUILD_RPI } BCM2708,BCM2835, {$endif}
{$ifdef BUILD_RPI2} BCM2709,BCM2836, {$endif}
{$ifdef BUILD_RPI3} BCM2710,BCM2837, {$endif}
GlobalConfig,GlobalConst,GlobalTypes,Platform,Threads,SysUtils,Classes,Console,Logging,Ultibo,
{$ifdef USE_WEB_STATUS} HTTP,WebStatus,SMSC95XX, {$endif}
Serial,DWCOTG,FileSystem,MMC,FATFS,Keyboard;

const 
 ScanUnitsPerSecond          = 1600;
 ScanInterval                = 5.000;
 ScanWindow                  = 0.500;

 HCI_COMMAND_PKT             = $01;
 HCI_EVENT_PKT               = $04;
 OGF_MARKER                  = $00;
 OGF_HOST_CONTROL            = $03;
 OGF_INFORMATIONAL           = $04;
 OGF_LE_CONTROL              = $08;
 OGF_VENDOR                  = $3f;
 LL_SCAN_PASSIVE             = $00;
 LL_SCAN_ACTIVE              = $01;

 ADV_IND                     = $00; // Connectable undirected advertising(default)
 ADV_DIRECT_IND_HI           = $01; // Connectable high duty cycle directed advertising
 ADV_SCAN_IND                = $02; // Scannable undirected advertising
 ADV_NONCONN_IND             = $03; // Non connectable undirected advertising
 ADV_DIRECT_IND_LO           = $04; // Connectable low duty cycle directed advertising

 // Advertising Data Types
 ADT_FLAGS                   = $01;      // Flags
 ADT_INCOMPLETE_UUID16       = $02;      // Incomplete List of 16-bit Service Class UUIDs
 ADT_COMPLETE_UUID16         = $03;      // Complete List of 16-bit Service Class UUIDs
 ADT_INCOMPLETE_UUID32       = $04;      // Incomplete List of 32-bit Service Class UUIDs
 ADT_COMPLETE_UUID32         = $05;      // Complete List of 32-bit Service Class UUIDs
 ADT_INCOMPLETE_UUID128      = $06;      // Incomplete List of 128-bit Service Class UUIDs
 ADT_COMPLETE_UUDI128        = $07;      // Complete List of 128-bit Service Class UUIDs
 ADT_SHORTENED_LOCAL_NAME    = $08;      // Shortened Local name
 ADT_COMPLETE_LOCAL_NAME     = $09;      // Complete Local name
 ADT_POWER_LEVEL             = $0A;      // Tx Power Level
 ADT_DEVICE_CLASS            = $0D;      // Class of Device
 ADT_SERVICE_DATA            = $16;      // Service data, starts with service uuid followed by data
 ADT_MANUFACTURER_SPECIFIC   = $FF;

 ManufacturerTesting         = $ffff;
 ManufacturerApple           = $004c;
 ManufacturerMicrosoft       = $0006;
 EddystoneUuid               = $feaa;

 BDADDR_LEN                  = 6;

type 
 TBDAddr = Array[0 .. BDADDR_LEN - 1] of Byte;
 TBluetoothWebStatus = class(TWebStatusCustom)
  function DoContent(AHost:THTTPHost;ARequest:THTTPServerRequest;AResponse:THTTPServerResponse):Boolean;override;
 end;
 TMessage = record
  Data:String;
  TimeStamp:LongWord;
  Rssi:Byte;
 end;
 TMessageTrack = record
  Key:String;
  Count:Integer;
  First:TMessage;
  Last:TMessage;
 end;

var 
 ExceptionRestartCounter:Integer;
 DropByte:Boolean;
 RestartBroadcastObserveLoop:Boolean;
 BluetoothUartDeviceDescription:String;
 BluetoothMiniDriverFileName:String;
 ScanCycleCounter:LongWord;
 ScanIdle:Boolean;
 StartTime:LongWord;
 Margin:LongWord;
 ReadBackLog:Integer;
 BluetoothWebStatus:TBluetoothWebStatus;
 LastDeviceStatus:LongWord;
 SerialDeviceStatusEntryCounter,SerialDeviceStatusExitCounter:LongWord;
 MessageTrackList:Array of TMessageTrack;
 AdData:Array of Byte;
 FWHandle:integer;
 HciSequenceNumber:Integer = 0;
 Console1,Console2:TWindowHandle;
 ch:char;
 UART0:PSerialDevice = Nil;
 KeyboardLoopHandle:TThreadHandle = INVALID_HANDLE_VALUE;
 MonitorLoopHandle:TThreadHandle = INVALID_HANDLE_VALUE;
 ReadByteCounter:Integer;
 Scheme:Array[0..3] of String = ('http://www.','https://www.','http://','https://');
 Expansion:Array[0..13] of String = ('.com/','.org/','.edu/','.net/','.info/','.biz','.gov/','.com','.org','.edu','.net','.info','.biz','.gov');

{$ifdef USE_WEB_STATUS}
 HTTPListener:THTTPListener;
{$endif}

function ReadByte:Byte; forward;
procedure StopAdvertising; forward;
procedure StartUndirectedAdvertising; forward;

procedure Log(s:string);
begin
 ConsoleWindowWriteLn(Console1,s);
end;

procedure RestoreBootFile(Prefix,FileName:String);
var 
 Source:String;
begin
 Source:=Prefix + '-' + FileName;
 Log(Format('Restoring from %s ...',[Source]));
 while not DirectoryExists('C:\') do
  sleep(500);
 if FileExists(Source) then
  CopyFile(PChar(Source),PChar(FileName),False);
 Log(Format('Restoring from %s done',[Source]));
end;

function TBluetoothWebStatus.DoContent(AHost:THTTPHost;ARequest:THTTPServerRequest;AResponse:THTTPServerResponse):Boolean;
begin
 AddItem(AResponse,'ExceptionRestartCounter',ExceptionRestartCounter.ToString);
 AddItem(AResponse,'ScanCycleCounter',ScanCycleCounter.ToString);
 AddItem(AResponse,'ReadByteCounter',ReadByteCounter.ToString);
 Result:=True;
end;

function ogf(op:Word):byte;
begin
 Result:=(op shr 10) and $3f;
end;

function ocf(op:Word):Word;
begin
 Result:=op and $3ff;
end;

function ErrToStr(code:byte):string;
begin
 case code of 
  $00:Result:='Success';
  $01:Result:='Unknown HCI Command';
  $02:Result:='Unknown Connection Identifier';
  $03:Result:='Hardware Failure';
  $04:Result:='Page Timeout';
  $05:Result:='Authentication Failure';
  $06:Result:='PIN or Key Missing';
  $07:Result:='Memory Capacity Exceeded';
  $08:Result:='Connection Timeout';
  $09:Result:='Connection Limit Exceeded';
  $0A:Result:='Synchronous Connection Limit To A Device Exceeded';
  $0B:Result:='ACL Connection Already Exists';
  $0C:Result:='Command Disallowed';
  $0D:Result:='Connection Rejected due to Limited Resources';
  $0E:Result:='Connection Rejected due To Security Reasons';
  $0F:Result:='Connection Rejected due to Unacceptable BD_ADDR';
  $10:Result:='Connection Accept Timeout Exceeded';
  $11:Result:='Unsupported Feature or Parameter Value';
  $12:Result:='Invalid HCI Command Parameters';
  $13:Result:='Remote User Terminated Connection';
  $14:Result:='Remote Device Terminated Connection due to Low Resources';
  $15:Result:='Remote Device Terminated Connection due to Power Off';
  $16:Result:='Connection Terminated By Local Host';
  $17:Result:='Repeated Attempts';
  $18:Result:='Pairing Not Allowed';
  $19:Result:='Unknown LMP PDU';
  $1A:Result:='Unsupported Remote Feature / Unsupported LMP Feature';
  $1B:Result:='SCO Offset Rejected';
  $1C:Result:='SCO Interval Rejected';
  $1D:Result:='SCO Air Mode Rejected';
  $1E:Result:='Invalid LMP Parameters / Invalid LL Parameters';
  $1F:Result:='Unspecified Error';
  $20:Result:='Unsupported LMP Parameter Value / Unsupported LL Parameter Value';
  $21:Result:='Role Change Not Allowed';
  $22:Result:='LMP Response Timeout / LL Response Timeout';
  $23:Result:='LMP Error Transaction Collision';
  $24:Result:='LMP PDU Not Allowed';
  $25:Result:='Encryption Mode Not Acceptable';
  $26:Result:='Link Key cannot be Changed';
  $27:Result:='Requested QoS Not Supported';
  $28:Result:='Instant Passed';
  $29:Result:='Pairing With Unit Key Not Supported';
  $2A:Result:='Different Transaction Collision';
  $2B:Result:='Reserved';
  $2C:Result:='QoS Unacceptable Parameter';
  $2D:Result:='QoS Rejected';
  $2E:Result:='Channel Classification Not Supported';
  $2F:Result:='Insufficient Security';
  $30:Result:='Parameter Out Of Mandatory Range';
  $31:Result:='Reserved';
  $32:Result:='Role Switch Pending';
  $33:Result:='Reserved';
  $34:Result:='Reserved Slot Violation';
  $35:Result:='Role Switch Failed';
  $36:Result:='Extended Inquiry Response Too Large';
  $37:Result:='Secure Simple Pairing Not Supported By Host';
  $38:Result:='Host Busy - Pairing';
  $39:Result:='Connection Rejected due to No Suitable Channel Found';
  $3A:Result:='Controller Busy';
  $3B:Result:='Unacceptable Connection Parameters';
  $3C:Result:='Directed Advertising Timeout';
  $3D:Result:='Connection Terminated due to MIC Failure';
  $3E:Result:='Connection Failed to be Established';
  $3F:Result:='MAC Connection Failed';
  $40:Result:='Coarse Clock Adjustment Rejected but Will Try to Adjust Using Clock';
 end;
end;

procedure Fail(Message:String);
begin
 raise Exception.Create(Message);
end;

procedure ClearAdvertisingData;
begin
 SetLength(AdData,0);
end;

procedure AddAdvertisingData (Type_ : byte; Data : array of byte); overload;
var 
 Len : byte;
 i : integer;
begin
 Len:=Length (AdData);
 SetLength (AdData, Len + length (Data) + 2);
 AdData[Len]:=Length (Data) + 1;
 AdData[Len + 1]:=Type_;
 for i:=0 to high (Data) do
  AdData[Len + 2 + i]:=Data[i];
end;

procedure AddAdvertisingData (Type_ : byte; Data : string); overload;
var 
 Len : byte;
 i : integer;
begin
 Len:=Length (AdData);
 SetLength (AdData, Len + length (Data) + 2);
 AdData[Len]:=Length (Data) + 1;
 AdData[Len + 1]:=Type_;
 for i:=1 to length (Data) do
  AdData[Len + 1 + i]:=ord (Data[i]);
end;

procedure AddAdvertisingData(Type_:byte); overload;
begin
 AddAdvertisingData (Type_, []);
end;

procedure HciCommand(OpCode:Word; Params:array of byte);
var 
 i:integer;
 Cmd:array of byte;
 res,count:LongWord;
 PacketType,EventCode,PacketLength,CanAcceptPackets,Status:Byte;
begin
 Inc(HciSequenceNumber);
 // if OpCode <> $fc4c then
 //  Log(Format('hci %d op %04.4x',[HciSequenceNumber,OpCode]));
 SetLength(Cmd,length(Params) + 4);
 Cmd[0]:=HCI_COMMAND_PKT;
 Cmd[1]:=lo(OpCode);
 Cmd[2]:=hi(OpCode);
 Cmd[3]:=length(Params);
 for i:=0 to length(Params) - 1 do
  Cmd[4 + i]:=Params[i];
 count:=0;
 res:=SerialDeviceWrite(UART0,@Cmd[0],length(Cmd),SERIAL_WRITE_NONE,count);
 if res = ERROR_SUCCESS then
  begin
   PacketType:=ReadByte;
   if PacketType <> HCI_EVENT_PKT then
    Fail(Format('event type not hci event: %d',[PacketType]));
   EventCode:=ReadByte;
   if EventCode <> $0E then
    Fail(Format('event code not command completed: %02.2x',[EventCode]));
   PacketLength:=ReadByte;
   if PacketLength <> 4 then
    Fail(Format('packet length not 4: %d',[PacketLength]));
   CanAcceptPackets:=ReadByte;
   if CanAcceptPackets <> 1 then
    Fail(Format('can accept packets not 1: %d',[CanAcceptPackets]));
   ReadByte; // completed command low
   ReadByte; // completed command high
   Status:=ReadByte;
   if Status <> 0 then
    Fail(Format('status not 0: %d',[Status]));
  end
 else
  Log('Error writing to BT.');
end;

procedure HciCommand(OGF:byte; OCF:Word; Params:array of byte);
begin
 HciCommand((OGF shl 10) or OCF,Params);
end;

procedure SetLEAdvertisingData(Data:array of byte);
var 
 Params:array of byte;
 Len:byte;
 i:integer;
begin
 Len:=Min(Length(Data),31);
 SetLength(Params,Len + 1);
 Params[0]:=Len;
 for i:=0 to Len - 1 do
  Params[i + 1]:=Data[i];
 HciCommand(OGF_LE_CONTROL,$08,Params);
end;

procedure UpdateBeacon;
var 
 EddystoneServiceData:Array of Byte;
 I:Integer;
 UpTime:Int64;
 Temperature:Double;
const 
 Part1 = 'ultibo';
procedure AddByte(X:Byte);
begin
 SetLength(EddystoneServiceData,Length(EddystoneServiceData) + 1);
 EddystoneServiceData[Length(EddystoneServiceData) - 1]:=X;
end;
procedure AddWord(X:Word);
begin
 AddByte(Hi(X));
 AddByte(Lo(X));
end;
procedure AddLongWord(X:LongWord);
begin
 AddWord(Hi(X));
 AddWord(Lo(X));
end;
begin
 SetLength(EddystoneServiceData,0);
 AddByte(Lo(EddystoneUuid));
 AddByte(Hi(EddystoneUuid));
 if (ScanCycleCounter mod 6) = 0 then
  begin
   AddByte($10);
   AddByte($00);
   AddByte($03);
   for I:=1 to Length(Part1) do
    AddByte(Ord(Part1[I]));
   AddByte($08);
  end
 else
  begin
   UpTime:=ClockGetTotal;
   Temperature:=TemperatureGetCurrent(TEMPERATURE_ID_SOC) / 1000;
   AddByte($20);
   AddByte($00);
   AddWord(4993);
   AddWord((Trunc(Temperature) shl 8) or Round((Temperature - Trunc(Temperature))*100));
   AddLongWord(UpTime div (1*1000*1000));
   AddLongWord(UpTime div (100*1000));
  end;
 ClearAdvertisingData;
 AddAdvertisingData(ADT_FLAGS,[$18]);
 AddAdvertisingData(ADT_COMPLETE_UUID16,[Lo(EddystoneUuid),Hi(EddystoneUuid)]);
 AddAdvertisingData(ADT_SERVICE_DATA,EddystoneServiceData);
 SetLEAdvertisingData(AdData);
end;

procedure SetLEAdvertisingParameters(MinInterval,MaxInterval:Word; Type_:byte; OwnAddressType,PeerAddressType:byte; PeerAddr:TBDAddr; ChannelMap,FilterPolicy:byte);
begin
 HciCommand(OGF_LE_CONTROL,$06,[lo(MinInterval),hi(MinInterval),
 lo(MaxInterval),hi(MaxInterval),
 Type_,OwnAddressType,PeerAddressType,
 PeerAddr[0],PeerAddr[1],PeerAddr[2],
 PeerAddr[3],PeerAddr[4],PeerAddr[5],
 ChannelMap,FilterPolicy]);
end;

procedure StartLeAdvertising;
var 
 ZeroAddress:TBDAddr = ($00,$00,$00,$00,$00,$00);
begin
 SetLEAdvertisingParameters(1000,1000,ADV_IND,$00,$00,ZeroAddress,$07,$00);
 UpdateBeacon;
 StartUndirectedAdvertising;
end;

function dBm(Rssi:Byte):String;
var 
 si:String;
begin
 if Rssi = 127 then si := 'NU'
 else if Rssi > 128 then si := '-' + IntToStr (256 - Rssi) + ' dBm'
 else if Rssi <= 20 then si := '+' + IntToStr (Rssi) + ' dBm'
 else si := '? dBm';
 Result:=si;
end;

procedure EndOfScan;
var 
 Now:LongWord;
 I:Integer;
const 
 Limit = 70*1000*1000;
procedure Cull;
var 
 NewList:Array of TMessageTrack;
 Track:TMessageTrack;
 I:Integer;
begin
 SetLength(NewList,0);
 for I:=0 to High(MessageTrackList) do
  begin
   Track:=MessageTrackList[I];
   if Now - Track.Last.TimeStamp <= Limit then
    begin
     SetLength(NewList,Length(NewList) + 1);
     NewList[Length(NewList) - 1]:=Track;
    end;
  end;
 MessageTrackList:=NewList;
end;
begin
 StopAdvertising;
 StartLeAdvertising;
 Now:=ClockGetCount;
 for I:=0 to High(MessageTrackList) do
  with MessageTrackList[I] do
   if Now - Last.TimeStamp > Limit then
    begin
     Cull;
     break;
    end;
 ConsoleWindowSetXY(Console2,1,1);
 for I:=High(MessageTrackList) downto 0 do
  with MessageTrackList[I] do
   begin
    if Now - Last.TimeStamp > Limit - 15*1000*1000 then
     ConsoleWindowSetForecolor(Console2,COLOR_RED)
    else if Now - Last.TimeStamp > Limit - 30*1000*1000 then
          ConsoleWindowSetForecolor(Console2,COLOR_GRAY);
    ConsoleWindowWrite(Console2,Format('%s %4d %s %s',[dBm(Last.Rssi),Count,Key,Last.Data]));
    ConsoleWindowSetForecolor(Console2,COLOR_YELLOW);
    ConsoleWindowClearEx(Console2,ConsoleWindowGetX(Console2),ConsoleWindowGetY(Console2),ConsoleWindowGetMaxX(Console2),ConsoleWindowGetY(Console2),False);
    ConsoleWindowWriteLn(Console2,'');
   end;
 ConsoleWindowClearEx(Console2,ConsoleWindowGetX(Console2),ConsoleWindowGetY(Console2),ConsoleWindowGetMaxX(Console2),ConsoleWindowGetMaxY(Console2),False);
end;

function EventReadFirstByte:Byte;
var 
 c:LongWord;
 b:Byte;
 res:Integer;
 Now:LongWord;
 EntryTime:LongWord;
begin
 Result:=0;
 EntryTime:=ClockGetCount;
 while ClockGetCount - EntryTime < 10*1000*1000 do
  begin
   Now:=ClockGetCount;
   c:=0;
   res:=SerialDeviceRead(UART0,@b,1,SERIAL_READ_NON_BLOCK,c);
   if (res = ERROR_SUCCESS) and (c = 1) then
    begin
     Result:=b;
     Inc(ReadByteCounter);
     if ScanIdle then
      begin
       ScanIdle:=False;
       StartTime:=Now;
       if (ScanCycleCounter >= 1) and ((Now - EntryTime) div 1000 < Margin) then
        begin
         Margin:=(Now - EntryTime) div 1000;
         LoggingOutput(Format('lowest available processing time between scans is now %5.3fS',[Margin / 1000]));
        end;
      end;
     exit;
    end
   else
    begin
     if (not ScanIdle) and (((Now - StartTime)/(1*1000*1000))  > (ScanWindow + 0.500))  then
      begin
       ScanIdle:=True;
       Inc(ScanCycleCounter);
       EndOfScan;
      end;
     ThreadYield;
    end;
  end;
 Fail('timeout waiting for serial read byte');
end;

function ReadByte:Byte;
var 
 c:LongWord;
 b:Byte;
 res:Integer;
 EntryTime:LongWord;
 SerialStatus:LongWord;
begin
 Result:=0;
 EntryTime:=ClockGetCount;
 while ClockGetCount - EntryTime < 1*1000*1000 do
  begin
   c:=0;
   res:=SerialDeviceRead(UART0,@b,1,SERIAL_READ_NON_BLOCK,c);
   if (res = ERROR_SUCCESS) and (c = 1) then
    begin
     if DropByte then
      begin
       DropByte:=False;
       break;
      end;
     Result:=b;
     Inc(ReadByteCounter);
     res:=SerialDeviceRead(UART0,@b,1,SERIAL_READ_PEEK_BUFFER,c);
     if c > ReadBackLog then
      begin
       ReadBackLog:=c;
       LoggingOutput(Format('highest SERIAL_READ_PEEK_BUFFER is now %d',[ReadBackLog]));
      end;
     Inc(SerialDeviceStatusEntryCounter);
     SerialStatus:=SerialDeviceStatus(UART0);
     Inc(SerialDeviceStatusExitCounter);
     SerialStatus:=SerialStatus and not (SERIAL_STATUS_RX_EMPTY or SERIAL_STATUS_TX_EMPTY);
     if SerialStatus <> LastDeviceStatus then
      begin
       LastDeviceStatus:=SerialStatus;
       LoggingOutput(Format('SerialDeviceStatus changed %08.8x',[SerialStatus]));
      end;
     exit;
    end
   else
    ThreadYield;
  end;
 Fail('timeout waiting for serial read byte');
end;

function IsBlueToothAvailable:Boolean;
begin
 Result:=True;
 Log(Format('Board is %s',[BoardTypeToString(BoardGetType)]));
 case BoardGetType of 
  BOARD_TYPE_RPI3B:
                   begin
                    BluetoothUartDeviceDescription:='BCM2837 PL011 UART';
                    BluetoothMiniDriverFileName:='BCM43430A1.hcd';
                   end;
  BOARD_TYPE_RPI3B_PLUS:
                        begin
                         BluetoothUartDeviceDescription:='BCM2837 PL011 UART';
                         BluetoothMiniDriverFileName:='BCM4345C0.hcd';
                        end;
  BOARD_TYPE_RPI_ZERO_W:
                        begin
                         BluetoothUartDeviceDescription:='BCM2835 PL011 UART';
                         BluetoothMiniDriverFileName:='BCM43430A1.hcd';
                        end;
  else
   begin
    Log('');
    Log('');
    Log('Bluetooth is not available on this board');
    Result:=False;
   end;
 end;
end;

function OpenUART0:boolean;
var 
 res:LongWord;
begin
 Result:=False;
 UART0:=SerialDeviceFindByDescription(BluetoothUartDeviceDescription);
 if UART0 = nil then
  begin
   Log('Can''t find UART0');
   exit;
  end;
 res:=SerialDeviceOpen(UART0,115200,SERIAL_DATA_8BIT,SERIAL_STOP_1BIT,SERIAL_PARITY_NONE,SERIAL_FLOW_NONE,0,0);
 if res = ERROR_SUCCESS then
  begin
   Result:=True;
   ReadBackLog:=0;
   LastDeviceStatus:=0;
   SerialDeviceStatusEntryCounter:=0;
   SerialDeviceStatusExitCounter:=0;

   GPIOFunctionSelect(GPIO_PIN_14,GPIO_FUNCTION_IN);
   GPIOFunctionSelect(GPIO_PIN_15,GPIO_FUNCTION_IN);

   GPIOFunctionSelect(GPIO_PIN_32,GPIO_FUNCTION_ALT3);     // TXD0
   GPIOFunctionSelect(GPIO_PIN_33,GPIO_FUNCTION_ALT3);     // RXD0

   GPIOPullSelect(GPIO_PIN_32,GPIO_PULL_NONE);             //Added
   GPIOPullSelect(GPIO_PIN_33,GPIO_PULL_UP);               //Added

   Sleep(50);
  end;
end;

procedure ResetChip;
begin
 HciCommand(OGF_HOST_CONTROL,$03,[]);
end;

procedure CloseUART0;
begin
 SerialDeviceClose(UART0);
 UART0:=Nil;
end;

procedure BCMLoadFirmware(fn:string);
var 
 hdr:array [0 .. 2] of byte;
 Params:array of byte;
 n,len:integer;
 Op:Word;
begin
 FWHandle:=FSFileOpen(fn,fmOpenRead);
 if FWHandle > 0 then
  begin
   Log('Firmware load ...');
   HciCommand(OGF_VENDOR,$2e,[]);
   n:=FSFileRead(FWHandle,hdr,3);
   while (n = 3) do
    begin
     Op:=(hdr[1] * $100) + hdr[0];
     len:=hdr[2];
     SetLength(Params,len);
     n:=FSFileRead(FWHandle,Params[0],len);
     if (len <> n) then Log('Data mismatch.');
     HciCommand(Op,Params);
     n:=FSFileRead(FWHandle,hdr,3);
    end;
   FSFileClose(FWHandle);
   CloseUart0;
   Sleep(50);
   OpenUart0;
   Sleep(50);
   Log('Firmware load done');
  end
 else
  Log('Error loading Firmware file ' + fn);
end;

procedure WaitForSDDrive;
begin
 while not DirectoryExists('C:\') do
  sleep(500);
end;

procedure StartLogging;
begin
 LOGGING_INCLUDE_COUNTER:=False;
 CONSOLE_REGISTER_LOGGING:=True;
 CONSOLE_LOGGING_POSITION:=CONSOLE_POSITION_BOTTOMRIGHT;
 LoggingConsoleDeviceAdd(ConsoleDeviceGetDefault);
 LoggingDeviceSetDefault(LoggingDeviceFindByType(LOGGING_TYPE_CONSOLE));
end;

procedure SetLEScanParameters(Type_:byte;Interval,Window:Word;OwnAddressType,FilterPolicy:byte);
begin
 HciCommand(OGF_LE_CONTROL,$0b,[Type_,lo(Interval),hi(Interval),lo(Window),hi(Window),OwnAddressType,FilterPolicy]);
end;

procedure SetLEScanEnable(State,Duplicates:boolean);
var 
 Params:Array of Byte;
begin
 SetLength(Params,2);
 if State then
  Params[0]:=$01
 else
  Params[0]:=$00;
 if Duplicates then
  Params[1]:=$01
 else
  Params[1]:=$00;
 HciCommand(OGF_LE_CONTROL,$0c,Params);
end;

procedure StartPassiveScanning;
begin
 SetLEScanParameters(LL_SCAN_PASSIVE,Round(ScanInterval*ScanUnitsPerSecond),Round(ScanWindow*ScanUnitsPerSecond),$00,$00);
 SetLEScanEnable(True,False);
end;

procedure StopScanning;
begin
 SetLEScanEnable(False,False);
end;

// le control
procedure SetLEEventMask(Mask:QWord);
var 
 Params:array of byte;
 MaskHi,MaskLo:DWord;
begin
 MaskHi:=(Mask shr 32) and $FFFFFFFF;
 MaskLo:=Mask and $FFFFFFFF;
 SetLength(Params,8);
 Params[0]:=MaskLo and $ff;   // lsb
 Params[1]:=(MaskLo shr 8) and $ff;
 Params[2]:=(MaskLo shr 16) and $ff;
 Params[3]:=(MaskLo shr 24) and $ff;
 Params[4]:=MaskHi and $ff;   // lsb
 Params[5]:=(MaskHi shr 8) and $ff;
 Params[6]:=(MaskHi shr 16) and $ff;
 Params[7]:=(MaskHi shr 24) and $ff;
 HciCommand(OGF_LE_CONTROL,$01,Params);
end;

function MonitorLoop(Parameter:Pointer):PtrInt;
var 
 Capture:LongWord;
begin
 Result:=0;
 while True do
  begin
   Sleep(1*1000);
   Capture:=SerialDeviceStatusExitCounter;
   if SerialDeviceStatusEntryCounter <> Capture then
    begin
     Sleep(2*1000);
     if SerialDeviceStatusExitCounter = Capture then
      begin
       LoggingOutput(Format('SerialDeviceStatus entry %d exit %d',[SerialDeviceStatusEntryCounter,SerialDeviceStatusExitCounter]));
       exit;
      end;
    end;
  end;
end;

procedure Help;
begin
 Log('H - Help - display this help message');
 Log('L - Loop - restart the broadcast/observe loop');
 Log('D - Drop Byte - drop one byte from the uart rx');
 Log('Q - Quit - use default-config.txt');
 Log('R - Restart - use bluetooth-dev-bluetoothtest-config.txt');
end;

function KeyboardLoop(Parameter:Pointer):PtrInt;
begin
 Result:=0;
 while True do
  begin
   if ConsoleGetKey(ch,nil) then
    case uppercase(ch) of 
     'H' : Help;
     'L' : RestartBroadcastObserveLoop:=True;
     'D' : DropByte:=True;
     'Q' : SystemRestart(0);
     'R' :
          begin
           RestoreBootFile('bluetooth-dev-bluetoothtest','config.txt');
           SystemRestart(0);
          end;
     'C' : ConsoleWindowClear(Console1);
    end;
  end;
end;

function AdvertisingTypeToStr(Type_:byte):string;
begin
 case Type_ of 
  ADV_IND           : Result:='connectable undirected advertising (default)';
  ADV_DIRECT_IND_HI : Result:='connectable high duty cycle directed advertising';
  ADV_SCAN_IND      : Result:='scannable undirected advertising';
  ADV_NONCONN_IND   : Result:='non-connectable undirected advertising';
  ADV_DIRECT_IND_LO : Result:='connectable low duty cycle directed advertising';
  else                Result:='reserved for future use (' + Type_.ToHexString(2) + ')';
 end;
end;

procedure SetLEAdvertisingEnable(State:boolean);
begin
 if State then
  HciCommand(OGF_LE_CONTROL,$0a,[$01])
 else
  HciCommand(OGF_LE_CONTROL,$0a,[$00]);
end;

procedure StartUndirectedAdvertising;
begin
 // ReadLEAdvertisingChannelTxPower;
 SetLEAdvertisingEnable(true);
end;

procedure StopAdvertising;
begin
 SetLEAdvertisingEnable(false);
end;

procedure Track(NewTimeStamp:LongWord;NewRssi:Byte;NewKey:String;NewData:String);
var 
 MessageTrack:TMessageTrack;
 I,N:Integer;
begin
 for I:=0 to High(MessageTrackList) do
  with MessageTrackList[I] do
   if NewKey = Key then
    begin
     Inc(Count);
     Last.Data:=NewData;
     Last.TimeStamp:=NewTimeStamp;
     Last.Rssi:=NewRssi;
     exit;
    end;
 N:=Length(MessageTrackList);
 SetLength(MessageTrackList,N + 1);
 Inc(N);
 for I:=N - 1 downto 1 do
  MessageTrackList[I]:=MessageTrackList[I - 1];
 MessageTrack.Key:=NewKey;
 MessageTrack.Count:=1;
 MessageTrack.First.Data:=NewData;
 MessageTrack.First.TimeStamp:=NewTimeStamp;
 MessageTrack.First.Rssi:=NewRssi;
 MessageTrack.Last:=MessageTrack.First;
 MessageTrackList[0]:=MessageTrack;
end;

procedure ParseEvent;
var 
 I:Integer;
 EventType,EventSubtype,EventLength:Byte;
 EddystoneLength,AdType,EddystoneLo,EddystoneHi,EddystoneType,TransmitPower,Rssi,C:Byte;
 TlmVersion:Byte;
 TlmBattery:Word;
 TlmTemperature:Word;
 TlmAdvCount:LongWord;
 TlmSecCount:LongWord;
 Event:Array of Byte;
 S:String;
 GetByteIndex:Integer;
 AddressString:String;
function GetByte:Byte;
begin
 Result:=Event[GetByteIndex];
 Inc(GetByteIndex);
end;
function GetWord:Word;
begin
 Result:=GetByte;
 Result:=GetByte or (Result shl 8);
end;
function GetLongWord:LongWord;
begin
 Result:=GetWord;
 Result:=GetWord or (Result shl 16);
end;
begin
 EventType:=EventReadFirstByte;
 EventSubtype:=Readbyte;
 EventLength:=ReadByte;
 SetLength(Event,0);
 S:='';
 for I:=1 to EventLength do
  begin
   SetLength(Event,Length(Event) + 1);
   Event[I - 1]:=ReadByte;
   S:=S+Event[I - 1].ToHexString(2) + ' ';
  end;
 if EventLength <= 37 then
  begin
   GetByteIndex:=4;
   AddressString:='';
   for I:=1 to 6 do
    AddressString:=GetByte.ToHexString(2) + AddressString;
   GetByteIndex:=18;
   EddystoneLength:=GetByte;
   AdType:=GetByte;
   EddystoneLo:=GetByte;
   EddystoneHi:=GetByte;
   EddystoneType:=GetByte;
   if (AdType = ADT_SERVICE_DATA) and (((EddystoneHi shl 8) or EddystoneLo) = EddystoneUuid) then
    begin
     if EddystoneType = $10 then
      begin
       TransmitPower:=GetByte;
       C:=GetByte;
       S:=Scheme[C];
       while GetByteIndex <= High(Event) - 1 do
        begin
         C:=GetByte;
         if C <= High(Expansion) then
          S:=S + Expansion[C]
         else
          S:=S + Char(C);
        end;
       Rssi:=GetByte;
       Track(ClockGetCount,Rssi,Format('%s eddystone url %s tx %s',[AddressString,S,dBm(TransmitPower)]),'');
      end
     else if EddystoneType = $20 then
           begin
            TlmVersion:=GetByte;
            TlmBattery:=GetWord;
            TlmTemperature:=GetWord;
            TlmAdvCount:=GetLongWord;
            TlmSecCount:=GetLongWord;
            Rssi:=GetByte;
            Track(ClockGetCount,Rssi,Format('%s tlm',[AddressString]),Format('ver %d battery %5.3fV temp %d.%02.2dC adv %d time %4.1fS',[TlmVersion,TlmBattery*0.001,(TlmTemperature shr 8),TlmTemperature and $ff,TlmAdvCount,TlmSecCount*0.1]));
           end;
    end;
  end;
 // else
 //  Log(Format('message %02.2x %02.2x %d bytes',[EventType,EventSubtype,EventLength]));
end;

procedure FlushRx;
var 
 Res:LongWord;
 C:LongWord;
 B:Byte;
 TimeStamp:LongWord;
begin
 TimeStamp:=ClockGetCount;
 while ClockGetCount - TimeStamp < 1*1000*1000 do
  begin
   Res:=SerialDeviceRead(UART0,@B,1,SERIAL_READ_NON_BLOCK,C);
   if (Res = ERROR_SUCCESS) and (C = 1) then
    TimeStamp:=ClockGetCount
   else
    Sleep(100);
  end;
end;

procedure Flush(Message:String);
begin
 LoggingOutput(Format('Flush %s',[Message]));
 FlushRx;
 try
  StopAdvertising;
 except
  on E:Exception do
       begin
        LoggingOutput(Format('Flush did not stop advertising %s',[E.Message]));
        FlushRx;
       end;
end;
try
 StopScanning;
except
 on E:Exception do
      begin
       LoggingOutput(Format('Flush did not stop scanning %s',[E.Message]));
       FlushRx;
      end;
end;
FlushRx;
end;

begin
 Console1 := ConsoleWindowCreate(ConsoleDeviceGetDefault,CONSOLE_POSITION_TOPRIGHT,True);
 Console2 := ConsoleWindowCreate(ConsoleDeviceGetDefault,CONSOLE_POSITION_LEFT,False);
 ConsoleWindowSetBackcolor(Console2,COLOR_BLACK);
 ConsoleWindowSetForecolor(Console2,COLOR_YELLOW);
 ConsoleWindowClear(Console2);
 Log('bluetooth-dev');
 RestoreBootFile('default','config.txt');
 StartLogging;
 BeginThread(@KeyboardLoop,Nil,KeyboardLoopHandle,THREAD_STACK_DEFAULT_SIZE);
 BeginThread(@MonitorLoop,Nil,MonitorLoopHandle,THREAD_STACK_DEFAULT_SIZE);
 Help;
 WaitForSDDrive;

{$ifdef USE_WEB_STATUS}
 HTTPListener:=THTTPListener.Create;
 HTTPListener.Active:=True;
 WEBSTATUS_FONT_NAME:='Monospace';
 WebStatusRegister(HTTPListener,'','',True);
 BluetoothWebStatus:=TBluetoothWebStatus.Create('Bluetooth','/bluetooth',2);
 HTTPListener.RegisterDocument('',BluetoothWebStatus);
{$endif}

 if IsBlueToothAvailable then
  begin
   ReadByteCounter:=0;
   OpenUart0;
   ResetChip;
   BCMLoadFirmware(BluetoothMiniDriverFileName);
   SetLEEventMask($ff);
   Log('Init complete');
   ExceptionRestartCounter:=0;
   ScanCycleCounter:=0;
   ReadByteCounter:=0;
   while True do
    begin
     try
      RestartBroadcastObserveLoop:=False;
      ReadBackLog:=0;
      DropByte:=False;
      StartLeAdvertising;
      Margin:=High(Margin);
      SetLength(MessageTrackList,0);
      StartPassiveScanning;
      Log('Receiving scan data');
      ScanIdle:=True;
      while not RestartBroadcastObserveLoop do
       ParseEvent;
     except
      on E:Exception do
           begin
            Inc(ExceptionRestartCounter);
            LoggingOutput(Format('ExceptionRestartCounter %d',[ExceptionRestartCounter]));
            Flush(E.Message);
           end;
    end;
  end;
end;
ThreadHalt(0);
end.

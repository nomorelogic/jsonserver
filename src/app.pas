unit app;

{$mode objfpc}{$H+}


interface

uses
  Classes, SysUtils, custhttpapp, fphttpapp, httproute, HTTPDefs, fpjson, fpjsonrtti, om, fgl;

type

  { TTimerObject }

  TTimerObject = class
  private
    FRequest: TRequest;
    Frequestor: string;
    FStart: TDateTime;
    procedure SetRequest(AValue: TRequest);
    procedure SetRequestor(AValue: string);
  public
    constructor Create;
    property Request: TRequest read FRequest write SetRequest;
    property Start: TDateTime read FStart;
    property Requestor: string read Frequestor write Setrequestor;
  end;

  TTimersHolder = specialize fgl.TFPGObjectList<TTimerObject>;

  { TTimersHolderHelper }

  TTimersHolderHelper = class helper for TTimersHolder
    function findByRequest(aRequest: TRequest): TTimerObject;
    procedure stopTimer(aTimer: TTimerObject);
  end;

  { TFakeJsonServer }

  TFakeJsonServer = class(TCustomHTTPApplication)
  private
    FConfig: TConfigObject;
    FTimers: TTimersHolder;
    procedure ExceptionHandle(Sender: TObject; E: Exception);
    procedure SetConfig(AValue: TConfigObject);
  protected
    procedure logRouters;
  public
    procedure StartRequest(Sender: TObject; ARequest: TRequest; AResponse: TResponse);
    procedure EndRequest(Sender: TObject; ARequest: TRequest; AResponse: TResponse);
    procedure Initialize; override;
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    property Config: TConfigObject read FConfig write SetConfig;
  protected
    procedure Response404(ARequest: TRequest; AResponse: TResponse);
  end;

var
  Application: TFakeJsonServer;
  ShowCleanUpErrors: boolean = False;

implementation

uses
  dateutils, CustApp, jsonparser, routers;

{ TTimersHolderHelper }

function TTimersHolderHelper.findByRequest(aRequest: TRequest): TTimerObject;
var
  cursor: TTimerObject;
begin
  Result := nil;
  for cursor in self do
  begin
    if cursor.Request = aRequest then
      Result := cursor;
  end;
end;

procedure TTimersHolderHelper.stopTimer(aTimer: TTimerObject);
var
  idx: integer;
begin
  if (aTimer <> nil) then
  begin
    idx := IndexOf(aTimer);
    if idx > -1 then
    begin
      Remove(aTimer);
      try
      except
        aTimer.Free;
      end;
    end;
  end;
end;

{ TTimerObject }

procedure TTimerObject.SetRequest(AValue: TRequest);
begin
  if FRequest = AValue then
    Exit;
  FRequest := AValue;
end;

procedure TTimerObject.Setrequestor(AValue: string);
begin
  if Frequestor = AValue then
    Exit;
  Frequestor := AValue;
end;

constructor TTimerObject.Create;
begin
  FStart := now;
end;

{ TFakeJsonServer }


procedure ShowRequestException(AResponse: TResponse; AnException: Exception; var handled: boolean);
begin
  Writeln(AResponse.Referer, ' ', AnException.ClassName, ' ', AnException.Message);
  AResponse.Code := 500;
  AResponse.Content := AnException.Message;
  handled := True;
end;

constructor TFakeJsonServer.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FConfig := TConfigObject.Create;
  FTimers := TTimersHolder.Create(True);
end;

destructor TFakeJsonServer.Destroy;
begin
  FreeAndNil(FTimers);
  FreeAndNil(FConfig);
  inherited Destroy;
end;

procedure TFakeJsonServer.Response404(ARequest: TRequest; AResponse: TResponse);
begin
  AResponse.Content := '{ status :400 }';
end;

procedure TFakeJsonServer.SetConfig(AValue: TConfigObject);
begin
  if FConfig = AValue then
    Exit;
  FConfig := AValue;
end;

function SortRouters(c1, c2: TCollectionItem): integer;
var
  r1, r2: THTTPRoute;
begin
  r1 := c1 as THTTPRoute;
  r2 := c2 as THTTPRoute;
  Result := Ord(r1.Method) - Ord(r2.Method);
  if Result = 0 then
    Result := CompareStr(r1.URLPattern, r2.URLPattern);
end;

procedure TFakeJsonServer.logRouters;
var
  rh: THTTPRoute;
  idx: integer;
begin
  if HTTPRouter.RouteCount > 0 then
    HTTPRouter.Routes[0].Collection.Sort(@SortRouters);
  for idx := 0 to HTTPRouter.RouteCount - 1 do
  begin
    rh := HTTPRouter.Routes[idx];
    Writeln(rh.Method: 10, rh.URLPattern: -100);
  end;
end;

procedure TFakeJsonServer.ExceptionHandle(Sender: TObject; E: Exception);
begin
  Writeln(e.ClassName, e.Message);
end;

procedure TFakeJsonServer.StartRequest(Sender: TObject; ARequest: TRequest; AResponse: TResponse);
var
  Timer: TTimerObject;
begin
  writeln(Format('%s:[%10s]%s', [ARequest.RemoteAddress, ARequest.Method, ARequest.URL]));
  Timer := TTimerObject.Create;
  Timer.Request := ARequest;
  Timer.requestor := Format('%s:[%10s]%s', [ARequest.RemoteAddress, ARequest.Method, ARequest.URL]);
  FTimers.Add(Timer);
end;

procedure TFakeJsonServer.EndRequest(Sender: TObject; ARequest: TRequest; AResponse: TResponse);
var
  timer: TTimerObject;
begin
  timer := FTimers.findByRequest(ARequest);
  if timer <> nil then
  begin
    Writeln(Timer.requestor, ' served in :', FormatDateTime('hh:nn:ss:zzzz', Now - Timer.start));
  end;
  FTimers.stopTimer(timer);
end;

procedure TFakeJsonServer.Initialize;
var
  FileStream: TFileStream;
  DeStreamer: TJSONDeStreamer;
  c: TCollectionItem;
  r: TRouterObject;
  jsonData: TJSONStringType;
  handle: TRouter;
begin
  inherited Initialize;
  Application.Threaded := True;
  OnException := @ExceptionHandle;
  OnShowRequestException := @ShowRequestException;
  RedirectOnError := True;
  FileStream := TFileStream.Create('config.json', fmOpenRead);
  SetLength(jsonData, FileStream.Size);
  FileStream.Read(jsonData[1], FileStream.Size);
  Writeln(jsonData);
  DeStreamer := TJSONDeStreamer.Create(nil);
  try
    DeStreamer.JSONToObject(jsonData, FConfig);
    Application.Port := Config.config.Port;
    for c in Config.routers do
    begin
      r := TRouterObject(c);
      if (r.Method <> '') and (r.Route <> '') then
      begin
        Writeln(r.Method, ' ', r.Route);
        if r.payload <> '' then
        begin
          handle := TPayloadRouter.Create(Application);
          TPayloadRouter(handle).compare := r.compare;
        end
        else
          handle := TRouter.Create(Application);
        if (r.outputTemplate <> '') and (r.outputKey <> '') then
        begin
          handle.output := TOutput.Create;
          handle.output.Template := r.outputTemplate;
          handle.output.Key := r.outputKey;
        end;
        handle.DataSetName := r.dataset;
        handle.Payload := r.payload;
        HTTPRouter.RegisterRoute(r.Route, getRouteMethod(r.Method), handle);
      end;
    end;
    logRouters;
  finally
    FreeAndNil(DeStreamer);
    FreeAndNil(FileStream);
  end;
  HTTPRouter.RegisterRoute('/stop', rmHead, TStopHandle.Create(self));
  HTTPRouter.BeforeRequest := @StartRequest;
  HTTPRouter.AfterRequest := @EndRequest;
end;


procedure InitHTTP;
begin
  Application := TFakeJsonServer.Create(nil);
  if not assigned(CustomApplication) then
    CustomApplication := Application;
end;

procedure DoneHTTP;
begin
  if CustomApplication = Application then
    CustomApplication := nil;
  try
    FreeAndNil(Application);
  except
    if ShowCleanUpErrors then
      raise;
  end;
end;

initialization
  InitHTTP;

finalization
  DoneHTTP;
end.



unit gltext;
//openGL Text using distance field fonts https://github.com/libgdx/libgdx/wiki/Distance-field-fonts
{$IFDEF FPC}
{$Include opts.inc}
{$mode objfpc}{$H+}
{$ENDIF}
interface

uses
  {$IFDEF FPC}
    {$IFDEF COREGL}glcorearb,  gl_core_matrix, {$ELSE}gl, glext, {$ENDIF} OpenGLContext,LResources,
  {$ELSE}
    dglOpenGL, glpanel, windows,pngimage,
  {$ENDIF}
   raycast_common, Dialogs,Classes, SysUtils, Graphics, math;

const
    kMaxChar = 2048; //maximum number of characters on screen, if >21845 change TPoint3i to uint32 and set glDrawElements to GL_UNSIGNED_INT
type
    TMetric = Packed Record //each vertex has position and texture coordinates
      x,y,xEnd,yEnd,w,h,xo,yo,xadv   : single; //position coordinates
    end;
    TMetrics = record
      M : array [0..255] of TMetric;
      lineHeight, base, scaleW, scaleH: single;
    end;
    Txyuv = Packed Record //each vertex has position and texture coordinates
      x,y   : single; //position coordinates
      u,v : single; //texture coordinates
    end;
    TRotMat = Packed Record //https://en.wikipedia.org/wiki/Rotation_matrix
            Xx,Xy, Yx,Yy: single;
    end;
    TQuad = array [0..3] of Txyuv; //each character rectangle has 4 vertices
  TGLText = class
  private
         {$IFDEF COREGL}vboVtx, vboIdx, vao,{$ELSE}displayLst,{$ENDIF} tex, shaderProgram: GLuint;
         {$IFDEF COREGL}uniform_mtx, {$ENDIF} uniform_clr, uniform_tex: GLint;
         fCrap, nChar, bmpHt, bmpWid: integer;
         isChanged: boolean;
         quads: array[0..(kMaxChar-1)] of TQuad;
         metrics: TMetrics;
         r,g,b: single;
    {$IFDEF COREGL}procedure LoadBufferData;{$ENDIF}
    function LoadMetrics(fnm : string): boolean;
    function LoadTex(fnm : string): boolean;
    procedure UpdateVbo;
    procedure CharOut(x,y,scale: single; rx: TRotMat; asci: byte);
  public
    property Crap : integer read fCrap;
    procedure ClearText; //remove all previous drawn text
    procedure TextOut(x,y,scale: single; s: string); overload; //add line of text
    procedure TextOut(x,y,scale, angle: single; s: string); overload; //add line of text
    function BaseHeight: single;
    function LineHeight: single;
    function TextWidth(scale: single; s: string): single;
    procedure TextColor(red,green,blue: byte);
    procedure DrawText;
    {$IFDEF FPC}
    procedure ChangeFontName(fntname: string; Ctx: TOpenGLControl);
    constructor Create(fntname : string; superSample: boolean; out success: boolean; Ctx: TOpenGLControl); //overlod;
    {$ELSE}
    procedure ChangeFontName(fntname: string; Ctx: TGLPanel);
    constructor Create(fntname : string; superSample: boolean; out success: boolean; Ctx: TGLPanel); //overlod;
    {$ENDIF}
    Destructor  Destroy; override;
  end;
  {$IFNDEF COREGL}var GLErrorStr : string = '';{$ENDIF}

implementation
{$IFNDEF FPC}{$R 'numbers.res'}{$ENDIF}


{$DEFINE TEX8BIT_NOT32} //we can save textures as 8-bit instead of 32-bit RGBA since we only need alpha
{$IFNDEF TEX8BIT_NOT32}
  Change ").r" to read ").r" in kFrag and kFragSuper
{$ENDIF}

const
{$IFDEF COREGL}
    kVert = '#version 330'
+#10'layout(location = 0) in vec2 point;'
+#10'layout(location = 1) in vec2 uvX;'
+#10'uniform mat4 ModelViewProjectionMatrix;'
+#10'out vec2 uv;'
+#10'void main() {'
+#10'    uv = uvX;'
+#10'    vec2 ptx = point;'
+#10'    gl_Position = ModelViewProjectionMatrix * vec4(ptx, -0.5, 1.0);'
+#10'}';

//super-sampling http://www.java-gaming.org/index.php?topic=33612.0
kFragSuper = '#version 330'
+#10'in vec2 uv;'
+#10'out vec4 color;'
+#10'uniform sampler2D tex;'
+#10'uniform vec4 clr;'
+#10'float contour(in float d, in float w) {'
+#10'  return smoothstep(0.5 - w, 0.5 + w, d);'
+#10'}'
+#10'float samp(in vec2 uv, float w) {'
+#10'  return contour(texture(tex, uv).r, w);'
+#10'}'
+#10'void main() {'
+#10'  float dist = texture(tex,uv).r;'
+#10'  float width = fwidth(dist);'
+#10'  float alpha = contour( dist, width );'
+#10'  float dscale = 0.354;'
+#10'  vec2 duv = dscale * (dFdx(uv) + dFdy(uv));'
+#10'  vec4 box = vec4(uv-duv, uv+duv);'
+#10'  float asum = samp( box.xy, width ) + samp( box.zw, width )+ samp( box.xw, width ) + samp( box.zy, width );'
+#10'  alpha = (alpha + 0.5 * asum) / 3.0;'
+#10'  color = vec4(clr.r,clr.g,clr.b,alpha);'
+#10'}';
kFrag = '#version 330'
+#10'in vec2 uv;'
+#10'out vec4 color;'
+#10'uniform sampler2D tex;'
+#10'uniform vec4 clr;'
+#10'const float smoothing = 1.0/16.0;'
+#10'void main() {'
+#10'  float dist = texture(tex,uv).r;'
+#10'  float alpha = smoothstep(0.5 - smoothing, 0.5 + smoothing, dist);'
+#10'  color = vec4(clr.r,clr.g,clr.b,alpha);'
+#10'}';
{$ELSE} //if core opengl, else legacy shaders
kVert ='varying vec4 vClr;'
+#10'void main() {'
+#10'    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;'
+#10'    vClr = gl_Color;'
+#10'}';

const kFrag = 'varying vec4 vClr;'
+#10'uniform sampler2D tex;'
+#10'uniform vec4 clr;'
+#10'const float smoothing = 1.0/16.0;'
+#10'void main() {'
+#10'  float dist = texture2D(tex,vClr.xy).r;'
+#10'  float alpha = smoothstep(0.5 - smoothing, 0.5 + smoothing, dist);'
+#10'  gl_FragColor = vec4(clr.rgb,alpha);'
+#10'  //gl_FragColor = vec4(clr.rgb, 1.0);'
+#10'}';

const kFragSuper = 'varying vec4 vClr;'
+#10'uniform sampler2D tex;'
+#10'uniform vec4 clr;'
+#10'float contour(in float d, in float w) {'
+#10'  return smoothstep(0.5 - w, 0.5 + w, d);'
+#10'}'
+#10'float samp(in vec2 uv, float w) {'
+#10'  return contour(texture2D(tex, uv).r, w);'
+#10'}'
+#10'const float smoothing = 1.0/16.0;'
+#10'void main() {'
+#10'  vec2 uv = vClr.xy;'
+#10'  float dist = texture2D(tex,uv).r;'
+#10'  float width = fwidth(dist);'
+#10'  float alpha = contour( dist, width );'
+#10'  float dscale = 0.354;'
+#10'  vec2 duv = dscale * (dFdx(uv) + dFdy(uv));'
+#10'  vec4 box = vec4(uv-duv, uv+duv);'
+#10'  float asum = samp( box.xy, width ) + samp( box.zw, width )+ samp( box.xw, width ) + samp( box.zy, width );'
+#10'  alpha = (alpha + 0.5 * asum) / 3.0;'
+#10'  gl_FragColor = vec4(clr.rgb,alpha);'
+#10'}';
{$ENDIF}
//{$DEFINE BINARYMETRICS} //binary metrics are faster than reading default metrics created by Hiero
{$IFDEF BINARYMETRICS}
procedure SaveMetricsBinary(fnm: string; fnt: TMetrics);
var
  f : File of TMetrics;
begin
  {$IFDEF ENDIAN_BIG}to do: byte-swap to little-endian  {$ENDIF}
  FileMode := fmOpenWrite;
  AssignFile(f, changefileext(fnm,'.fnb'));
  ReWrite(f, 1);
  Write(f, fnt);
  CloseFile(f);
  FileMode := fmOpenRead;
end;

function LoadMetricsBinary(fnm: string; out fnt: TMetrics): boolean;
var
  f : File of TMetrics;
begin
  result := false;
  fnm := changefileext(fnm,'.fnb');
  if not fileexists(fnm) then exit;
  FileMode := fmOpenRead;
  AssignFile(f, fnm);
  Reset(f, 1);
  Read(f, fnt);
  CloseFile(f);
  {$IFDEF ENDIAN_BIG}to do: byte-swap from little-endian  {$ENDIF}
  result := true;
end;
{$ENDIF} // BINARYMETRICS

function LoadMetricsAsci(fnm: string; out fnt: TMetrics): boolean;
var
   flst, strlst : TStringList;
   {$IFDEF FPC}
   r: TLResource;
   {$ELSE}
   r : TResourceStream;
   {$ENDIF}
   s: string;
   fLine,id, pages: integer;
function GetFntVal(key: string): single;
var
   i,p: integer;
begin
  result := 0;
  for i := 1 to (strlst.Count-1) do begin
        if pos(key,strlst[i]) <> 1 then continue;
        p :=  length(key)+2;
        result := strtofloatdef(copy(strlst[i],p,length(strlst[i])-p+1 ),0);
        break;
  end;
end;
begin
  result := false;
  for id := 0 to 255 do begin
      fnt.M[id].x := 0;
      fnt.M[id].y := 0;
      fnt.M[id].xEnd := 0;
      fnt.M[id].yEnd := 0;
      fnt.M[id].w := 0;
      fnt.M[id].h := 0;
      fnt.M[id].xo := 0;
      fnt.M[id].yo := 0;
      fnt.M[id].xadv := 0; //critical to set: fnt format omits non-graphical characters (e.g. DEL): we skip characters whete X-advance = 0
  end;
  fLst := TStringList.Create;
  if fnm = '' then begin
    {$IFDEF FPC}
    r:=LazarusResources.Find('fnt');
    if r=nil then raise Exception.Create('resource fnt is missing');
    fLst.StrictDelimiter := true;
    fLst.Delimiter := chr(10);
    fLst.DelimitedText:=r.Value;
    {$ELSE}
     r := TResourceStream.Create(hInstance,'FNT',RT_RCDATA);
     fLst.LoadFromStream(r);
     r.free;
    {$ENDIF}
  end else
      fLst.LoadFromFile(fnm);
  if fLst.Count < 2 then exit;
  strlst:=TStringList.Create;
  for fLine := 0 to fLst.Count-1 do begin
        s := fLst[fLine]; //make sure to run CheckMesh after this, as these are indexed from 1!
        if (length(s) < 1) or (s[1] = '#') then continue;
        strlst.DelimitedText := s;
        if strlst.Count < 7 then continue;
        if (strlst[0] = 'common') then begin
           fnt.lineHeight := GetFntVal('lineHeight');
           fnt.base := GetFntVal('base');
           fnt.scaleW := GetFntVal('scaleW');
           fnt.scaleH := GetFntVal('scaleH');
           pages := round(GetFntVal('pages'));
           if (pages <> 1) then begin
              showmessage('Only able to read single page fonts');
              exit;
           end;
        end;
        if (strlst[0] <> 'char') then continue;
        id := round(GetFntVal('id'));
        if (id < 0) or (id > 255) then continue;
        fnt.M[id].x:=GetFntVal('x');
        fnt.M[id].y:=GetFntVal('y');
        fnt.M[id].w:=GetFntVal('width');
        fnt.M[id].h:=GetFntVal('height');
        fnt.M[id].xo:=GetFntVal('xoffset');
        fnt.M[id].yo:=GetFntVal('yoffset');
        fnt.M[id].xadv:=GetFntVal('xadvance');
  end;
  fLst.free;
  strlst.free;
  if (fnt.scaleW < 1) or (fnt.scaleH < 1) then exit;
  for id := 0 to 255 do begin //normalize from pixels to 0..1
      fnt.M[id].yo := fnt.base - (fnt.M[id].h + fnt.M[id].yo);
      fnt.M[id].x:=fnt.M[id].x/fnt.scaleW;
      fnt.M[id].y:=fnt.M[id].y/fnt.scaleH;
      fnt.M[id].xEnd := fnt.M[id].x + (fnt.M[id].w/fnt.scaleW);
      fnt.M[id].yEnd := fnt.M[id].y + (fnt.M[id].h/fnt.scaleH);
  end;
  result := true;
end;

procedure Rot(xK,yK, x,y: single; r: TRotMat; out Xout, Yout: single);
// rotate points x,y and add to constant offset xK,yK
begin
     Xout := xK + (x * r.Xx) + (y * r.Xy);
     Yout := yK + (x * r.Yx) + (y * r.Yy);
end;

procedure TGLText.CharOut(x,y,scale: single; rx: TRotMat; asci: byte);
var
  q: TQuad;
  x0,x1,y0,y1: single;
begin
  if metrics.M[asci].w = 0 then exit; //nothing to draw, e.g. SPACE character
  if nChar > kMaxChar then nChar := 0; //overflow!
  x0 := (scale * metrics.M[asci].xo);
  x1 := x0 + (scale * metrics.M[asci].w);
  y0 := (scale * metrics.M[asci].yo);
  y1 := y0 + (scale * metrics.M[asci].h);
  Rot(x,y, x0, y0, rx, q[0].x, q[0].y);
  Rot(x,y, x0, y1, rx, q[1].x, q[1].y);
  Rot(x,y, x1, y0, rx, q[2].x, q[2].y);
  Rot(x,y, x1, y1, rx, q[3].x, q[3].y);
  q[0].u := metrics.M[asci].x;
  q[1].u := q[0].u;
  q[2].u := metrics.M[asci].xEnd;
  q[3].u := q[2].u;
  q[0].v := metrics.M[asci].yEnd;
  q[1].v := metrics.M[asci].y;
  q[2].v := q[0].v;
  q[3].v := q[1].v;
  quads[nChar] := q;
  isChanged := true;
  nChar := nChar + 1;
end; //CharOut()

procedure TGLText.TextOut(x,y,scale, angle: single; s: string); //overload
var
  i: integer;
  asci: byte;
  rx: TRotMat;
begin
  angle := DegToRad(angle);
  rx.Xx := cos(angle);
  rx.Xy := -sin(angle);
  rx.Yx := sin(angle);
  rx.Yy := cos(angle);
  if length(s) < 1 then exit;
  for i := 1 to length(s) do begin
      asci := ord(s[i]);
      if metrics.M[asci].xadv = 0 then continue; //not in dataset
      CharOut(x,y,scale,rx,asci);
      Rot(x,y, (scale * metrics.M[asci].xadv),0, rx, x, y);
  end;
end; //TextOut()

procedure TGLText.TextOut(x,y,scale: single; s: string); //overload;
begin
     TextOut(x,y,scale,0,s);
end; //TextOut()

function TGLText.BaseHeight: single;
begin
  result := metrics.base;
end;

function TGLText.LineHeight: single;
begin
     result := metrics.lineHeight;
end;

function TGLText.TextWidth(scale: single; s: string): single;
var
  i: integer;
  asci: byte;
begin
  result := 0;
  if length(s) < 1 then exit;
  for i := 1 to length(s) do begin
      asci := ord(s[i]);
      if metrics.M[asci].xadv = 0 then continue; //not in dataset
      result := result + (scale * metrics.M[asci].xadv);
  end;
end; //TextWidth()

procedure TGLText.TextColor(red,green,blue: byte);
begin
     r := red/255;
     g := green/255;
     b := blue/255;
end;

procedure TGLText.ClearText;
begin
  nChar := 0;
end; //ClearText()

{$IFDEF COREGL}
procedure TGLText.UpdateVbo;
begin
  if (nChar < 1) or (not isChanged) then exit;

  glBindBuffer(GL_ARRAY_BUFFER, vboVtx);
  glBufferSubData(GL_ARRAY_BUFFER,0,nChar * sizeof(TQuad),@quads[0]);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  isChanged := false;
end; //UpdateVbo()
{$ELSE} //not CoreGL
procedure TGLText.UpdateVbo;
var
  z,i: integer;
  q: TQuad;
begin
  if (nChar < 1) or (not isChanged) then exit;
  if displayLst <> 0 then
     glDeleteLists(displayLst, 1);
  displayLst := glGenLists(1);
  glNewList(displayLst, GL_COMPILE);
  z := -1;
  glBegin(GL_TRIANGLES);
  for i := 0 to (nChar-1) do begin
      q := quads[i];
      glColor3f(Q[0].u, Q[0].v, 1.0);
      glVertex3f(Q[0].x, Q[0].y, z);
      glColor3f(Q[1].u, Q[1].v, 1.0);
      glVertex3f(Q[1].x, Q[1].y, z);
      glColor3f(Q[2].u, Q[2].v, 1.0);
      glVertex3f(Q[2].x, Q[2].y, z);
      glColor3f(Q[2].u, Q[2].v, 1.0);
      glVertex3f(Q[2].x, Q[2].y, z);
      glColor3f(Q[1].u, Q[1].v, 1.0);
      glVertex3f(Q[1].x, Q[1].y, z);
      glColor3f(Q[3].u, Q[3].v, 1.0);
      glVertex3f(Q[3].x, Q[3].y, z);
  end;
  glEnd();
  glEndList();
  isChanged := false;
end; //UpdateVbo()
{$ENDIF}

{$IFDEF COREGL}
procedure TGLText.LoadBufferData;
type
    TPoint3i = Packed Record
      x,y,z   : uint16; //vertex indices: for >65535 indices use uint32 and use GL_UNSIGNED_INT for glDrawElements
    end;
const
    kATTRIB_POINT = 0; //XY position on screen
    kATTRIB_UV = 1; //UV coordinates of texture
var
    faces: array of TPoint3i;
    i,j,k: integer;
begin
  uniform_clr := glGetUniformLocation(shaderProgram, pAnsiChar('clr'));
  uniform_tex := glGetUniformLocation(shaderProgram, pAnsiChar('tex'));
  glGenBuffers(1, @vboVtx);
  glBindBuffer(GL_ARRAY_BUFFER, vboVtx);
  glBufferData(GL_ARRAY_BUFFER, kMaxChar * sizeof(TQuad), nil, GL_DYNAMIC_DRAW); //GL_STATIC_DRAW
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glGenVertexArrays(1, @vao);
  glBindVertexArray(vao);
  glBindBuffer(GL_ARRAY_BUFFER, vboVtx);
  glVertexAttribPointer(kATTRIB_POINT, 2, GL_FLOAT, GL_FALSE, sizeof(Txyuv), PChar(0));
  glEnableVertexAttribArray(kATTRIB_POINT);
  glVertexAttribPointer(kATTRIB_UV, 2, GL_FLOAT, GL_FALSE, sizeof(Txyuv), PChar(sizeof(single)*2));
  glEnableVertexAttribArray(kATTRIB_UV);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glBindVertexArray(0);
  uniform_mtx := glGetUniformLocation(shaderProgram, pAnsiChar('ModelViewProjectionMatrix'));
  glGenBuffers(1, @vboIdx);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, vboIdx);
  setlength(faces, kMaxChar * 2 ); //each character composed of 2 triangles
  for i := 0 to ((kMaxChar)-1) do begin
      j := i * 2;
      k := i * 4;
      faces[j].x := 0+k;
      faces[j].y := 1+k;
      faces[j].z := 2+k;
      faces[j+1].x := 2+k;
      faces[j+1].y := 1+k;
      faces[j+1].z := 3+k;
  end;
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, Length(faces)*sizeof(TPoint3i), @faces[0], GL_STATIC_DRAW);
  setlength(faces, 0 );
end;
{$ENDIF}

function TGLText.LoadTex(fnm: string): boolean;
var
  {$IFDEF FPC}
  px: TPicture;
  Ptr: PByte;
  {$ELSE}
  PNG: TPNGObject;
  RS : TResourceStream;
  pScanline: pngimage.pByteArray;
  {$ENDIF}
  {$IFDEF TEX8BIT_NOT32} //save 75% of texture size by only saving A not RGBA
  ra: array of byte;
  x,y,i: integer;
  {$ENDIF}
begin
  result := false;
  if (fnm <> '') and (not fileexists(fnm)) then begin
     fnm := changefileext(fnm,'.png');
     if not fileexists(fnm) then
        exit;

  end;
  {$IFDEF FPC}
  px := TPicture.Create;
  try
    if fnm = '' then
       px.LoadFromLazarusResource('png')
    else
        px.LoadFromFile(fnm);
  except
    px.Bitmap.Width:=0;
  end;
  //showmessage(format('bmp %d %d',[px.Bitmap.Width, px.Bitmap.Height]));
  if (px.Bitmap.PixelFormat <> pf32bit ) or (px.Bitmap.Width < 1) or (px.Bitmap.Height < 1) then begin
  {$ELSE}
  PNG := TPNGObject.Create;
  try
    if fnm = '' then begin
      RS := TResourceStream.Create(hInstance,'PNG',RT_RCDATA);
      PNG.LoadFromStream(RS);
      RS.Free;
    end else
      PNG.LoadFromFile(fnm);

  except
    PNG.Transparent:=false;
  end;
  if (not PNG.Transparent) or (PNG.Width < 1) or (PNG.Height < 1) then begin
  {$ENDIF}
     showmessage(format('Error loading 32-bit power-of-two bitmap %s',[fnm]));
     exit;
  end;
  glGenTextures(1, @tex);
  glBindTexture(GL_TEXTURE_2D,  tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
{$IFDEF FPC}
  bmpHt := px.Bitmap.Height;
  bmpWid := px.Bitmap.Width;
  {$IFDEF TEX8BIT_NOT32}
  setlength(ra, px.Width * px.Height);
  i := 0;
  for y:= 1 to px.Height do begin
      Ptr := px.Bitmap.RawImage.GetLineStart(y);
      Inc(PByte(Ptr), 3);
      for x := 1 to px.Width do begin
          ra[i] := Ptr^;
          Inc(PByte(Ptr), 4);
          i := i + 1;
      end;
  end;
  glTexImage2D(GL_TEXTURE_2D, 0,GL_RED, px.Width, px.Height, 0, GL_RED, GL_UNSIGNED_BYTE, @ra[0]);
  setlength(ra,0);
  {$ELSE}
  glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA8, px.Width, px.Height, 0, GL_BGRA, GL_UNSIGNED_BYTE, PInteger(px.Bitmap.RawImage.Data));
  {$ENDIF}
  px.Free;
{$ELSE}
  bmpHt := PNG.Height;
  bmpWid := PNG.Width;
  i := 0;
  setlength(ra, bmpHt * bmpWid);
  for y := 0 to bmpHt - 1 do begin
      pScanline := PNG.AlphaScanline[y];
      for x := 0 to PNG.Width - 1 do begin
        ra[i] :=  pScanline[x];
        i := i + 1;
      end;
  end;
  glTexImage2D(GL_TEXTURE_2D, 0,GL_RED, bmpWid, bmpHt, 0, GL_RED, GL_UNSIGNED_BYTE, @ra[0]);
  setlength(ra,0);
  png.free;
{$ENDIF}
  result := true;
end;

function TGLText.LoadMetrics(fnm : string): boolean;
var
   fntfnm: string;
begin
     {$IFDEF BINARYMETRICS}if LoadMetricsBinary(fnm,metrics) then exit;{$ENDIF}
     if fnm = '' then
        fntfnm := ''
     else
        fntfnm := changefileext(fnm,'.fnt');
     result := LoadMetricsAsci(fntfnm,metrics);
     {$IFDEF BINARYMETRICS}SaveMetricsBinary(fntfnm,metrics);{$ENDIF}
end;

{$IFDEF FPC}
constructor TGLText.Create(fntname: string; superSample: boolean; out success: boolean; Ctx: TOpenGLControl);
{$ELSE}
constructor TGLText.Create(fntname: string; superSample: boolean; out success: boolean; Ctx: TGLPanel);
{$ENDIF}
begin
  success := true;
  tex := 0;
  shaderProgram := 0;
  {$IFDEF COREGL}
  vboVtx := 0;
  vboIdx := 0;
  vao := 0;
  uniform_mtx := 0;
  {$ELSE}
  displayLst := 0;
  {$ENDIF}
  uniform_clr := 0;
  uniform_tex := 0;
  r := 1;
  g := 1;
  b := 1;
  nChar := 0;
  isChanged := false;
  Ctx.MakeCurrent();
  if superSample then
     shaderProgram :=  initVertFrag(kVert, kFragSuper)
  else
      shaderProgram :=  initVertFrag(kVert, kFrag);
  if shaderProgram = 0 then success := false;
  if not LoadTex(fntname) then success := false;
  if not LoadMetrics(fntname) then success := false;
  uniform_clr := glGetUniformLocation(shaderProgram, pAnsiChar('clr'));
  uniform_tex := glGetUniformLocation(shaderProgram, pAnsiChar('tex'));
  {$IFDEF COREGL}LoadBufferData;{$ENDIF}
  //glFinish;
  Ctx.ReleaseContext;
end;

procedure TGLText.DrawText;
{$IFDEF COREGL}
var
  mvp : TnMat44;
{$ENDIF}
begin
  fCrap:= nChar*10 + random(10);
  if nChar < 1 then exit; //nothing to draw
  glUseProgram(shaderProgram);
  UpdateVbo;
  glUniform4f(uniform_clr, r, g, b, 1.0);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, tex);
  glUniform1i(uniform_tex, 1);
  {$IFDEF COREGL}
  mvp := ngl_ModelViewProjectionMatrix;
  glUniformMatrix4fv(uniform_mtx, 1, GL_FALSE, @mvp[0,0]);
  glBindVertexArray(vao);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,vboIdx);
  glDrawElements(GL_TRIANGLES,  nChar * 2* 3, GL_UNSIGNED_SHORT, nil); //each quad 2 triangles each with 3 indices
  glBindVertexArray(0);
  {$ELSE}
  glCallList(displayLst);
  {$ENDIF}
  glUseProgram(0);
end;

destructor TGLText.Destroy;
begin
  //call the parent destructor:
  inherited;
end;

{$IFDEF FPC}
procedure TGLText.ChangeFontName(fntname: string; Ctx: TOpenGLControl);
{$ELSE}
procedure TGLText.ChangeFontName(fntname: string; Ctx: TGLPanel);
{$ENDIF}
begin
  Ctx.MakeCurrent();
  glDeleteTextures(1, @tex);
   LoadTex(fntname);
   LoadMetrics(fntname);
   Ctx.ReleaseContext;
end;

initialization
{$IFDEF FPC}
 {$I fnt.lrs}
{$ENDIF}
end.


#ifndef SWELL_PROVIDED_BY_APP


#include "swell.h"
#include "swell-dlggen.h"

#import <Cocoa/Cocoa.h>
#include <AudioUnit/AudioUnit.h>
#include <AudioUnit/AUCocoaUIView.h>

#ifndef SWELL_CUT_OUT_COMPOSITING_MIDDLEMAN
#define SWELL_CUT_OUT_COMPOSITING_MIDDLEMAN 1 // 2 gives more performance, not correctly drawn window frames (try NSThemeFrame stuff? bleh)
#endif

static HMENU g_swell_defaultmenu,g_swell_defaultmenumodal;

void (*SWELL_DDrop_onDragLeave)();
void (*SWELL_DDrop_onDragOver)(POINT pt);
void (*SWELL_DDrop_onDragEnter)(void *hGlobal, POINT pt);
const char* (*SWELL_DDrop_getDroppedFileTargetPath)(const char* extension);

bool SWELL_owned_windows_levelincrease=false;

#include "swell-internal.h"
#include "../wdlstring.h"
#include "../wdlcstring.h"

#define NSColorFromCol(a) [NSColor colorWithCalibratedRed:GetRValue(a)/255.0f green:GetGValue(a)/255.0f blue:GetBValue(a)/255.0f alpha:1.0f]
extern int g_swell_terminating;

static LRESULT sendSwellMessage(id obj, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
  if (obj && [obj respondsToSelector:@selector(onSwellMessage:p1:p2:)])
    return [(SWELL_hwndChild *)obj onSwellMessage:uMsg p1:wParam p2:lParam];
  return 0;
}

static BOOL Is105Plus()
{
  static char is105;
  if (!is105)
  {
    SInt32 v=0x1040;
    Gestalt(gestaltSystemVersion,&v);
    is105 = v>=0x1050 ? 1 : -1;    
  }
  return is105>0;
}

static BOOL useNoMiddleManCocoa() { return Is105Plus(); }

void updateWindowCollection(NSWindow *w)
{
  static SInt32 ver;
  if (!ver)
  {
    Gestalt(gestaltSystemVersion,&ver);
    if (!ver) ver=0x1040;
  }
  if (ver>=0x1060)
  {
    const int NSWindowCollectionBehaviorParticipatesInCycle = 1 << 5;
    const int  NSWindowCollectionBehaviorManaged = 1 << 2;
    [(SWELL_WindowExtensions*)w setCollectionBehavior:NSWindowCollectionBehaviorManaged|NSWindowCollectionBehaviorParticipatesInCycle];
  }
}

static void DrawSwellViewRectImpl(SWELL_hwndChild *view, NSRect rect, HDC hdc);
static void swellRenderOptimizely(int passflags, SWELL_hwndChild *view, HDC hdc, BOOL doforce, WDL_PtrList<void> *needdraws, const NSRect *rlist, int rlistcnt, int draw_xlate_x, int draw_xlate_y, bool iscv);

static LRESULT SWELL_SendMouseMessage(NSView *slf, int msg, NSEvent *event);
static LRESULT SWELL_SendMouseMessageImpl(SWELL_hwndChild *slf, int msg, NSEvent *theEvent)
{
 
  NSView *capv=(NSView *)GetCapture();
  if (capv && capv != slf && [capv window] == [slf window] && [capv isKindOfClass:[SWELL_hwndChild class]])
    return SWELL_SendMouseMessage((SWELL_hwndChild*)capv,msg,theEvent);
  
  if (slf->m_hashaddestroy||!slf->m_wndproc) return -1;
  
  NSPoint swellProcessMouseEvent(int msg, NSView *view, NSEvent *event);
  
  NSPoint p = swellProcessMouseEvent(msg,slf,theEvent);
  unsigned short xpos=(int)floor(p.x); 
  unsigned short ypos=(int)floor(p.y);
  
  LRESULT htc=HTCLIENT;
  if (msg != WM_MOUSEWHEEL && msg != WM_MOUSEHWHEEL && !capv) 
  { 
    DWORD p=GetMessagePos(); 
    htc=slf->m_wndproc((HWND)slf,WM_NCHITTEST,0,p); 
    if (slf->m_hashaddestroy||!slf->m_wndproc) return -1; // if somehow WM_NCHITTEST destroyed us, bail
    
    if (htc!=HTCLIENT) 
    { 
      if (msg==WM_MOUSEMOVE) return slf->m_wndproc((HWND)slf,WM_NCMOUSEMOVE,htc,p); 
      if (msg==WM_LBUTTONUP) return slf->m_wndproc((HWND)slf,WM_NCLBUTTONUP,htc,p); 
      if (msg==WM_LBUTTONDOWN) return slf->m_wndproc((HWND)slf,WM_NCLBUTTONDOWN,htc,p); 
      if (msg==WM_LBUTTONDBLCLK) return slf->m_wndproc((HWND)slf,WM_NCLBUTTONDBLCLK,htc,p); 
      if (msg==WM_RBUTTONUP) return slf->m_wndproc((HWND)slf,WM_NCRBUTTONUP,htc,p); 
      if (msg==WM_RBUTTONDOWN) return slf->m_wndproc((HWND)slf,WM_NCRBUTTONDOWN,htc,p); 
      if (msg==WM_RBUTTONDBLCLK) return slf->m_wndproc((HWND)slf,WM_NCRBUTTONDBLCLK,htc,p); 
      if (msg==WM_MBUTTONUP) return slf->m_wndproc((HWND)slf,WM_NCMBUTTONUP,htc,p); 
      if (msg==WM_MBUTTONDOWN) return slf->m_wndproc((HWND)slf,WM_NCMBUTTONDOWN,htc,p); 
      if (msg==WM_MBUTTONDBLCLK) return slf->m_wndproc((HWND)slf,WM_NCMBUTTONDBLCLK,htc,p); 
    } 
  } 
  
  int l=0;
  if (msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL)
  {
    float dw = (msg == WM_MOUSEWHEEL ? [theEvent deltaY] : [theEvent deltaX]);
    //if (!dy) dy=[theEvent deltaX]; // shift+mousewheel sends deltaX instead of deltaY
    l = (int)(dw*60.0);
    l <<= 16;
    
    // put todo: modifiers into low word of l?
    
    POINT p;
    GetCursorPos(&p);
    return slf->m_wndproc((HWND)slf,msg,l,(p.x&0xffff) + (p.y<<16));
  }
  
  LRESULT ret=slf->m_wndproc((HWND)slf,msg,l,(xpos&0xffff) + (ypos<<16));
  
  if (msg==WM_LBUTTONUP || msg==WM_RBUTTONUP || msg==WM_MOUSEMOVE || msg==WM_MBUTTONUP) {
    if (!GetCapture() && (slf->m_hashaddestroy || !slf->m_wndproc || !slf->m_wndproc((HWND)slf,WM_SETCURSOR,(WPARAM)slf,htc | (msg<<16)))) {
      NSCursor *arr= [NSCursor arrowCursor];
      if (GetCursor() != (HCURSOR)arr) SetCursor((HCURSOR)arr);
    }
  }
  return ret;  
}
static LRESULT SWELL_SendMouseMessage(NSView *slf, int msg, NSEvent *event)
{
  if (!slf) return 0;
  [slf retain];
  LRESULT res=SWELL_SendMouseMessageImpl((SWELL_hwndChild*)slf,msg,event);
  [slf release];
  return res;
}

void SWELL_DoDialogColorUpdates(HWND hwnd, DLGPROC d, bool isUpdate)
{
  extern HDC__ *SWELL_GDP_CTX_NEW();
  NSArray *children = [(NSView *)hwnd subviews];
  
  if (!d || !children || ![children count]) return;

  int had_flags=0;

  NSColor *staticFg=NULL; // had_flags&1, WM_CTLCOLORSTATIC
  NSColor *editFg=NULL, *editBg=NULL; // had_flags&2, WM_CTLCOLOREDIT
  NSColor *buttonFg=NULL; // had_flags&4, WM_CTLCOLORBTN
      
  int x;
  for (x = 0; x < [children count]; x ++)
  {
    NSView *ch = [children objectAtIndex:x];
    if (ch)
    {
      if ([ch isKindOfClass:[NSButton class]] && [(NSButton *)ch image])
      {
        if (!buttonFg && !(had_flags&4))
        {
          had_flags|=4;
          HDC__ *c = SWELL_GDP_CTX_NEW();
          if (c)
          {
            d(hwnd,WM_CTLCOLORBTN,(WPARAM)c,(LPARAM)ch);
            if (c->curtextcol) buttonFg=NSColorFromCol(c->cur_text_color_int);
            else if (isUpdate) buttonFg = [NSColor textColor]; // todo some other col?              
            if (buttonFg) [buttonFg retain];

            SWELL_DeleteGfxContext((HDC)c);
          }
        }
        if (buttonFg) [(NSTextField*)ch setTextColor:buttonFg]; // NSButton had this added below
      }
      else if ([ch isKindOfClass:[NSTextField class]] || [ch isKindOfClass:[NSBox class]])
      {
        bool isbox = ([ch isKindOfClass:[NSBox class]]);        
        if (!isbox && [(NSTextField *)ch isEditable])
        {
#if 0 // no color overrides for editable text fields
          if (!editFg && !editBg && !(had_flags&2))
          {
            had_flags|=2;
            HDC__ *c = SWELL_GDP_CTX_NEW();
            if (c)
            {
              d(hwnd,WM_CTLCOLOREDIT,(WPARAM)c,(LPARAM)ch);
              if (c->curtextcol)
              {
                editFg=NSColorFromCol(c->cur_text_color_int);
                editBg=[NSColor colorWithCalibratedRed:GetRValue(c->curbkcol)/255.0f green:GetGValue(c->curbkcol)/255.0f blue:GetBValue(c->curbkcol)/255.0f alpha:1.0f];
              }
              else if (isUpdate) 
              {
                editFg = [NSColor textColor]; 
                editBg = [NSColor textBackgroundColor];
              }
              if (editFg) [editFg retain];
              if (editBg) [editBg retain];
              SWELL_DeleteGfxContext((HDC)c);
            }
          }
          if (editFg) [(NSTextField*)ch setTextColor:editFg]; 
          if (editBg) [(NSTextField*)ch setBackgroundColor:editBg];
#endif
        }
        else // isbox or noneditable
        {
          if (!staticFg && !(had_flags&1))
          {
            had_flags|=1;
            HDC__ *c = SWELL_GDP_CTX_NEW();
            if (c)
            {
              d(hwnd,WM_CTLCOLORSTATIC,(WPARAM)c,(LPARAM)ch);
              if (c->curtextcol) staticFg=NSColorFromCol(c->cur_text_color_int);
              else if (isUpdate) 
              {
                staticFg = [NSColor textColor]; 
              }
              if (staticFg) [staticFg retain];
              SWELL_DeleteGfxContext((HDC)c);
            }
          }
          if (staticFg)
          {
            if (isbox) 
            {
              [[(NSBox*)ch titleCell] setTextColor:staticFg];
              //[(NSBox*)ch setBorderColor:staticFg]; // see comment at SWELL_MakeGroupBox
            }
            else
            {
              [(NSTextField*)ch setTextColor:staticFg]; 
            }
          }
        } // noneditable           
      }  //nstextfield
    } // child
  }     // children
  if (buttonFg) [buttonFg release];
  if (staticFg) [staticFg release];
  if (editFg) [editFg release];
  if (editBg) [editBg release];
}  

static LRESULT SwellDialogDefaultWindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
  DLGPROC d=(DLGPROC)GetWindowLong(hwnd,DWL_DLGPROC);
  if (d) 
  {
    if (uMsg == WM_PAINT)
    {
      if (!d(hwnd,WM_ERASEBKGND,0,0))
      {
        bool nommc=useNoMiddleManCocoa();
        NSView *cv = [[(NSView *)hwnd window] contentView];
        bool isop = [(NSView *)hwnd isOpaque] || (nommc && [cv isOpaque]);
        if (isop || cv == (NSView *)hwnd)
        {
          PAINTSTRUCT ps;
          if (BeginPaint(hwnd,&ps))
          {
            RECT r=ps.rcPaint;          
            if (!nommc && !(((SWELL_hwndChild*)hwnd)->m_isdirty&1))
            {
              NSArray *ar = [(NSView *)hwnd subviews];
              int x,n=[ar count];
              for (x=0;x<n;x++)
              {
                NSView *v = [ar objectAtIndex:x];
                if (![v isOpaque])
                {
                  NSRect f = [v frame];
                  if (NSIntersectsRect(f,NSMakeRect(r.left,r.top,r.right-r.left,r.bottom-r.top))) break;
                }
              }     
              if (x>=n) r.right=r.left; // disable drawing
            }
            
            if (r.right > r.left && r.bottom > r.top)
            {
              HBRUSH hbrush = (HBRUSH) d(hwnd,WM_CTLCOLORDLG,(WPARAM)ps.hdc,(LPARAM)hwnd);
              if (hbrush && hbrush != (HBRUSH)1)
              {
    //            char bf[512];
  //              GetWindowText(hwnd,bf,sizeof(bf));
//                static int a;
                //  printf("%d filled custom bg, (%p %s) %d %d %d %d\n",a++,hwnd,bf,r.left,r.top,r.right-r.left,r.bottom-r.top);
                FillRect(ps.hdc,&r,hbrush);
              }
              else if (isop) // no need to do this fill if it is a content view and is not opaque
              {
                //            char bf[512];
                //              GetWindowText(hwnd,bf,sizeof(bf));
                //                static int a;
                // printf("%d: filled stock bg, (%p %s) %d %d %d %d\n",a++,hwnd,bf,r.left,r.top,r.right-r.left,r.bottom-r.top);
                SWELL_FillDialogBackground(ps.hdc,&r,3);
              }
            }
            EndPaint(hwnd,&ps);
          }        
        }
      }
    }
    
    LRESULT r=(LRESULT) d(hwnd,uMsg,wParam,lParam);   
   
    if (r) return r; 
  }
  return DefWindowProc(hwnd,uMsg,wParam,lParam);
}

static SWELL_DialogResourceIndex *resById(SWELL_DialogResourceIndex *reshead, const char *resid)
{
  SWELL_DialogResourceIndex *p=reshead;
  while (p)
  {
    if (p->resid == resid) return p;
    p=p->_next;
  }
  return 0;
}

static void DoPaintStuff(WNDPROC wndproc, HWND hwnd, HDC hdc, NSRect *modrect)
{
  RECT r;
  GetWindowRect(hwnd,&r);
  if (r.top>r.bottom) { int tmp=r.top; r.top=r.bottom; r.bottom=tmp; }
  NCCALCSIZE_PARAMS p={{r,},};
  wndproc(hwnd,WM_NCCALCSIZE,FALSE,(LPARAM)&p);
  RECT r2=r;
  r=p.rgrc[0];

  wndproc(hwnd,WM_NCPAINT,(WPARAM)1,0);
  modrect->origin.x += r.left-r2.left;
  modrect->origin.y += r.top-r2.top;
    
  if (modrect->size.width >= 1 && modrect->size.height >= 1)
  {
    int a=0;
    if (memcmp(&r,&r2,sizeof(r)))
    {
      RECT tr;
      SWELL_PushClipRegion(hdc);
      GetClientRect(hwnd,&tr);
      SWELL_SetClipRegion(hdc,&tr);
      a++;
    }
    wndproc(hwnd,WM_PAINT,(WPARAM)hdc,0);
    if (a) SWELL_PopClipRegion(hdc);
  }
}


static int DelegateMouseMove(NSView *view, NSEvent *theEvent)
{
  static int __nofwd;
  if (__nofwd) return 0;

  NSWindow *w=[theEvent window];
  if (!w) return 0;

  NSPoint p=[theEvent locationInWindow];
  NSPoint screen_p=[w convertBaseToScreen:p];

  NSWindow *bestwnd = w;
  HWND cap = GetCapture();
  if (!cap)
  {
    // if not captured, find the window that should receive this event

    NSArray *windows=[NSApp orderedWindows];
    int x,cnt=windows ? [windows count] : 0;
    NSWindow *kw = [NSApp keyWindow];
    if (kw && windows && [windows containsObject:kw]) kw=NULL;
    // make sure the keywindow, if any, is checked, but not twice

    for (x = kw ? -1 : 0; x < cnt; x ++)
    {
      NSWindow *wnd = x < 0 ? kw : [windows objectAtIndex:x];
      if (wnd && [wnd isVisible])
      {
        NSRect fr=[wnd frame];
        if (screen_p.x >= fr.origin.x && screen_p.x < fr.origin.x + fr.size.width &&
            screen_p.y >= fr.origin.y && screen_p.y < fr.origin.y + fr.size.height)
        {
          bestwnd=wnd;
          break;
        }    
      }
    }
  }

  if (bestwnd == w || [NSApp modalWindow])
  {
    NSView *v=[[w contentView] hitTest:p];
    if (!v || v == view) return 0; // default processing if in view, or if in nonclient area

    __nofwd=1;
    [v mouseMoved:theEvent];
    __nofwd=0;
    return 1;
  }

  // bestwnd != w
  NSView *cv = [bestwnd contentView];
  if (cv && [cv isKindOfClass:[SWELL_hwndChild class]])
  {
    p = [bestwnd convertScreenToBase:screen_p];
    NSView *v=[cv hitTest:p];
    if (v)
    {
      theEvent = [NSEvent mouseEventWithType:[theEvent type] 
                            location:p 
                            modifierFlags:[theEvent modifierFlags]
                            timestamp:[theEvent timestamp]
                            windowNumber:[bestwnd windowNumber] 
                            context:[bestwnd graphicsContext] 
                            eventNumber:[theEvent eventNumber] 
                            clickCount:[theEvent clickCount]
                            pressure:[theEvent pressure]];
      __nofwd=1;
      [v mouseMoved:theEvent];
      __nofwd=0;
      return 1;
    }
  }
  if (!cap)
  {
    // set default cursor, and eat message
    NSCursor *arr= [NSCursor arrowCursor];
    if (GetCursor() != (HCURSOR)arr) SetCursor((HCURSOR)arr);
    return 1;
  }
  return 0;
}




@implementation SWELL_hwndChild : NSView 

-(void)viewDidHide
{
  SendMessage((HWND)self, WM_SHOWWINDOW, FALSE, 0);
}
-(void) viewDidUnhide
{
  SendMessage((HWND)self, WM_SHOWWINDOW, TRUE, 0);
}

- (void)SWELL_Timer:(id)sender
{ 
  extern HWND g_swell_only_timerhwnd;
  if (g_swell_only_timerhwnd && (HWND)self != g_swell_only_timerhwnd) return;
  
  id uinfo=[sender userInfo];
  if ([uinfo respondsToSelector:@selector(getValue)]) 
  {
    WPARAM idx=(WPARAM)[(SWELL_DataHold*)uinfo getValue];
    if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_TIMER,idx,0);
  }
}

- (int)swellCapChangeNotify { return YES; }

- (LRESULT)onSwellMessage:(UINT)msg p1:(WPARAM)wParam p2:(LPARAM)lParam
{
  if (m_hashaddestroy)
  {
    if (m_hashaddestroy==2 || msg == WM_DESTROY || msg == WM_CAPTURECHANGED) return 0;
  }
  
  
  if (msg==WM_DESTROY) // only ever called once per window
  { 
    m_hashaddestroy=1; 
    if (GetCapture()==(HWND)self) ReleaseCapture(); 
    SWELL_MessageQueue_Clear((HWND)self); 

    LRESULT ret=m_wndproc ? m_wndproc((HWND)self,msg,wParam,lParam) : 0;

    if ([[self window] contentView] == self && [[self window] respondsToSelector:@selector(swellDestroyAllOwnedWindows)])
      [(SWELL_ModelessWindow*)[self window] swellDestroyAllOwnedWindows];

    if (GetCapture()==(HWND)self) ReleaseCapture(); 
    SWELL_MessageQueue_Clear((HWND)self); 
    
    if (m_menu) 
    {
      if ((HMENU)[NSApp mainMenu] == m_menu && !g_swell_terminating) [NSApp setMainMenu:nil];
      SWELL_SetMenuDestination(m_menu,NULL);
      [(NSMenu *)m_menu release]; 
      m_menu=0;
    }
    NSView *v=self;
    NSArray *ar;
    if (v && [v isKindOfClass:[NSView class]] && (ar=[v subviews]) && [ar count]>0) 
    {
      int x; 
      for (x = 0; x < [ar count]; x ++) 
      {
        NSView *sv=[ar objectAtIndex:x]; 
        sendSwellMessage(sv,WM_DESTROY,0,0);
      }
    }
    KillTimer((HWND)self,~(UINT_PTR)0);
    m_hashaddestroy=2;

    return ret;
  }
  
  return m_wndproc ? m_wndproc((HWND)self,msg,wParam,lParam) : 0;
}

- (void) setEnabled:(BOOL)en
{ 
  m_enabled=en; 
} 

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex 
{
  if ([aTableView isKindOfClass:[SWELL_ListView class]])
  {
    SWELL_ListView *f = (SWELL_ListView *)aTableView;
    if (f->m_selColors&&[aTableView isRowSelected:rowIndex]) 
    {
      int cnt = [f->m_selColors count];
      int offs = GetFocus() == (HWND)aTableView ? 0 : 2;
      if (cnt>=offs+2)
      {
        if ([aCell respondsToSelector:@selector(setTextColor:)]) [aCell setTextColor:[f->m_selColors objectAtIndex:(offs+1)]];
        return;
      }
    }

    if (f->m_fgColor && [aCell respondsToSelector:@selector(setTextColor:)]) [aCell setTextColor:f->m_fgColor];
  }
}
- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
  if ([outlineView isKindOfClass:[SWELL_TreeView class]])
  {
    SWELL_TreeView *f = (SWELL_TreeView *)outlineView;
    if (f->m_selColors)
    {
      HTREEITEM sel = TreeView_GetSelection((HWND)outlineView);
      if (sel && sel->m_dh == item)
      {
        int cnt = [f->m_selColors count];
        int offs = GetFocus() == (HWND)outlineView ? 0 : 2;
        if (cnt>=offs+2)
        {
          if ([cell respondsToSelector:@selector(setTextColor:)]) [cell setTextColor:[f->m_selColors objectAtIndex:(offs+1)]];
          return;
        }
      }
    }
    if (f->m_fgColor && [cell respondsToSelector:@selector(setTextColor:)]) [cell setTextColor:f->m_fgColor];
  }
}


//- (void)outlineView:(NSOutlineView *)outlineView willDisplayOutlineCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn item:(id)item

- (void)comboBoxWillPopUp:(NSNotification*)notification
{
  id sender=[notification object];
  int code=CBN_DROPDOWN;
  if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_COMMAND,([(NSControl*)sender tag])|(code<<16),(LPARAM)sender);
}

- (void)comboBoxSelectionDidChange:(NSNotification *)notification
{
  id sender=[notification object];
  int code=CBN_SELCHANGE;
  if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_COMMAND,([(NSControl*)sender tag])|(code<<16),(LPARAM)sender);
}

- (void)textDidEndEditing:(NSNotification *)aNotification
{
  id sender=[aNotification object];
  int code=EN_CHANGE;
  if ([sender isKindOfClass:[NSComboBox class]]) return;
  if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_COMMAND,([(NSControl*)sender tag])|(code<<16),(LPARAM)sender);
}

- (void)controlTextDidChange:(NSNotification *)aNotification
{
  id sender=[aNotification object];
  int code=EN_CHANGE;
  if ([sender isKindOfClass:[NSComboBox class]]) code=CBN_EDITCHANGE;
  if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_COMMAND,([(NSControl*)sender tag])|(code<<16),(LPARAM)sender);
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
  if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_INITMENUPOPUP,(WPARAM)menu,0);
}

-(void) swellOnControlDoubleClick:(id)sender
{
  if (!m_wndproc||m_hashaddestroy) return;
  
  if ([sender isKindOfClass:[NSTableView class]] && 
      [sender respondsToSelector:@selector(getSwellNotificationMode)])
  {
    if ([(SWELL_ListView*)sender getSwellNotificationMode])
      m_wndproc((HWND)self,WM_COMMAND,(LBN_DBLCLK<<16)|[(NSControl*)sender tag],(LPARAM)sender);
    else
    {
      SWELL_ListView* v = (SWELL_ListView*)sender;
      NMLISTVIEW nmlv={{(HWND)sender,[(NSControl*)sender tag], NM_DBLCLK}, [v clickedRow], [sender clickedColumn], };
      SWELL_ListView_Row *row=v->m_items->Get(nmlv.iItem);
      if (row)
       nmlv.lParam = row->m_param;
      m_wndproc((HWND)self,WM_NOTIFY,[(NSControl*)sender tag],(LPARAM)&nmlv);
    }
  }
  else
  {   
    NMCLICK nm={{(HWND)sender,[(NSControl*)sender tag],NM_DBLCLK}, }; 
    m_wndproc((HWND)self,WM_NOTIFY,[(NSControl*)sender tag],(LPARAM)&nm);
  }
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
  NSOutlineView *sender=[notification object];
  NMTREEVIEW nmhdr={{(HWND)sender,(int)[sender tag],TVN_SELCHANGED},0,};  // todo: better treeview notifications
  if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_NOTIFY,(int)[sender tag],(LPARAM)&nmhdr);
}
- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
  NSTableView *sender=[aNotification object];
      if ([sender respondsToSelector:@selector(getSwellNotificationMode)] && [(SWELL_ListView*)sender getSwellNotificationMode])
      {
        if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_COMMAND,(int)[sender tag] | (LBN_SELCHANGE<<16),(LPARAM)sender);
      }
      else
      {
        NMLISTVIEW nmhdr={{(HWND)sender,(int)[sender tag],LVN_ITEMCHANGED},(int)[sender selectedRow],0}; 
        if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_NOTIFY,(int)[sender tag],(LPARAM)&nmhdr);
        
      }
}

- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn
{
  if ([tableView isKindOfClass:[SWELL_ListView class]] && 
      ((SWELL_ListView *)tableView)->m_cols && 
      !((SWELL_ListView *)tableView)->m_lbMode &&
      !(((SWELL_ListView *)tableView)->style & LVS_NOSORTHEADER)
      )
  {
    int col=((SWELL_ListView *)tableView)->m_cols->Find(tableColumn);

    NMLISTVIEW hdr={{(HWND)tableView,[tableView tag],LVN_COLUMNCLICK},-1,col};
    if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_NOTIFY,[tableView tag], (LPARAM) &hdr);
  }
}

-(void) onSwellCommand:(id)sender
{
  if (!m_wndproc || m_hashaddestroy) return;
  
  if ([sender isKindOfClass:[NSSlider class]])
  {
    m_wndproc((HWND)self,WM_HSCROLL,0,(LPARAM)sender);
    //  WM_HSCROLL, WM_VSCROLL
  }
  else if ([sender isKindOfClass:[NSTableView class]])
  {
  #if 0
    if ([sender isKindOfClass:[NSOutlineView class]])
    {
//      NMTREEVIEW nmhdr={{(HWND)sender,(int)[sender tag],TVN_SELCHANGED},0,};  // todo: better treeview notifications
  //    m_wndproc((HWND)self,WM_NOTIFY,(int)[sender tag],(LPARAM)&nmhdr);
    }
    else
    {
    
      if ([sender respondsToSelector:@selector(getSwellNotificationMode)] && [(SWELL_ListView*)sender getSwellNotificationMode])
      {
        m_wndproc((HWND)self,WM_COMMAND,(int)[sender tag] | (LBN_SELCHANGE<<16),(LPARAM)sender);
      }
      else
      {
        NMLISTVIEW nmhdr={{(HWND)sender,(int)[sender tag],LVN_ITEMCHANGED},(int)[sender clickedRow],0}; 
        m_wndproc((HWND)self,WM_NOTIFY,(int)[sender tag],(LPARAM)&nmhdr);
      }
    }
    #endif
  }
  else
  {
    int cw=0;
    if ([sender isKindOfClass:[NSComboBox class]]) return; // combo boxes will use delegate messages
    else if ([sender isKindOfClass:[NSPopUpButton class]]) 
    {
      cw=CBN_SELCHANGE;
    }
    else if ([sender isKindOfClass:[SWELL_Button class]])
    {
      int rf;
      if ((rf=(int)[(SWELL_Button*)sender swellGetRadioFlags]))
      {
        NSView *par=(NSView *)GetParent((HWND)sender);
        if (par && [par isKindOfClass:[NSWindow class]]) par=[(NSWindow *)par contentView];
        if (par && [par isKindOfClass:[NSView class]])
        {
          NSArray *ar=[par subviews];
          if (ar)
          {
            NSInteger x=[ar indexOfObject:sender];
            if (x != NSNotFound)
            {
              int n=[ar count];
              int a=x;
              if (!(rf&2)) while (--a >= 0)
              {
                NSView *item=[ar objectAtIndex:a];
                if (!item || ![item isKindOfClass:[SWELL_Button class]]) break; // we may want to allow other controls in there, but for now if it's non-button we're done
                int bla=(int)[(SWELL_Button*)item swellGetRadioFlags]; 
                if (bla&1) if ([(NSButton *)item state]!=NSOffState) [(NSButton *)item setState:NSOffState];                
                if (bla&2) break;
              }
              a=x;
              while (++a < n)
              {
                NSView *item=[ar objectAtIndex:a];
                if (!item || ![item isKindOfClass:[SWELL_Button class]]) break; // we may want to allow other controls in there, but for now if it's non-button we're done
                int bla=(int)[(SWELL_Button*)item swellGetRadioFlags];
                if (bla&2) break;              
                if (bla&1) if ([(NSButton *)item state]!=NSOffState) [(NSButton *)item setState:NSOffState];                
              }
            }
          }
        }
      }
    }
    else if ([sender isKindOfClass:[NSControl class]])
    {
      NSEvent *evt=[NSApp currentEvent];
      int ty=evt?[evt type]:0;
      if (evt && (ty==NSLeftMouseDown || ty==NSLeftMouseUp) && [evt clickCount] > 1) cw=STN_DBLCLK;
    }
    else if ([sender isKindOfClass:[NSMenuItem class]])
    {
//      [[sender menu] update];
      // wish we could force the top level menu to update here, meh
    }
    m_wndproc((HWND)self,WM_COMMAND,[sender tag]|(cw<<16),(LPARAM)sender);
  }

}
-(void) dealloc
{

  int x;
  for (x=0;x<sizeof(m_access_cacheptrs)/sizeof(m_access_cacheptrs[0]);x ++)
  {
    if (m_access_cacheptrs[x]) [m_access_cacheptrs[x] release];
    m_access_cacheptrs[x]=0;
  }
  KillTimer((HWND)self,~(UINT_PTR)0);
  [self onSwellMessage:WM_DESTROY p1:0 p2:0];
  if (GetCapture()==(HWND)self) ReleaseCapture();
  if (m_glctx)
  {
    [m_glctx release];
    m_glctx=0;
  }
  [super dealloc];
}

-(NSInteger)tag { return m_tag; }
-(void)setTag:(NSInteger)t { m_tag=t; }
-(LONG_PTR)getSwellUserData { return m_userdata; }
-(void)setSwellUserData:(LONG_PTR)val {   m_userdata=val; }
-(LPARAM)getSwellExtraData:(int)idx { idx/=sizeof(INT_PTR); if (idx>=0&&idx<sizeof(m_extradata)/sizeof(m_extradata[0])) return m_extradata[idx]; return 0; }
-(void)setSwellExtraData:(int)idx value:(LPARAM)val { idx/=sizeof(INT_PTR); if (idx>=0&&idx<sizeof(m_extradata)/sizeof(m_extradata[0])) m_extradata[idx] = val; }
-(void)setSwellWindowProc:(WNDPROC)val { m_wndproc=val; }
-(WNDPROC)getSwellWindowProc { return m_wndproc; }
-(void)setSwellDialogProc:(DLGPROC)val { m_dlgproc=val; }
-(DLGPROC)getSwellDialogProc { return m_dlgproc; }
-(BOOL)isFlipped {   return m_flip; }
-(void) getSwellPaintInfo:(PAINTSTRUCT *)ps
{
  if (m_paintctx_hdc)
  {
    m_paintctx_used=1;
    ps->hdc = m_paintctx_hdc;
    ps->fErase=false;
    ps->rcPaint.left = (int)m_paintctx_rect.origin.x;
    ps->rcPaint.right = (int)ceil(m_paintctx_rect.origin.x+m_paintctx_rect.size.width);
    ps->rcPaint.top = (int)m_paintctx_rect.origin.y;
    ps->rcPaint.bottom  = (int)ceil(m_paintctx_rect.origin.y+m_paintctx_rect.size.height);
  }
}

-(bool)swellCanPostMessage { return !m_hashaddestroy; }
-(int)swellEnumProps:(PROPENUMPROCEX)proc lp:(LPARAM)lParam 
{
  WindowPropRec *p=m_props;
  if (!p) return -1;
  while (p) 
  {
    WindowPropRec *ps=p;
    p=p->_next;
    if (!proc((HWND)self, ps->name, ps->data, lParam)) return 0;
  }
  return 1;
}

-(void *)swellGetProp:(const char *)name wantRemove:(BOOL)rem 
{
  WindowPropRec *p=m_props, *lp=NULL;
  while (p) 
  {
    if (p->name < (void *)65536) 
    {
      if (name==p->name) break;
    }
    else if (name >= (void *)65536) 
    {
      if (!strcmp(name,p->name)) break;
    }
    lp=p; p=p->_next;
  }
  if (!p) return NULL;
  void *ret=p->data;
  if (rem) 
  {
    if (lp) lp->_next=p->_next; else m_props=p->_next; 
    free(p);
  }
  return ret;
}

-(int)swellSetProp:(const char *)name value:(void *)val 
{
  WindowPropRec *p=m_props;
  while (p) 
  {
    if (p->name < (void *)65536) 
    {
      if (name==p->name) { p->data=val; return TRUE; };
    }
    else if (name >= (void *)65536) 
    {
      if (!strcmp(name,p->name)) { p->data=val; return TRUE; };
    }
    p=p->_next;
  }
  p=(WindowPropRec*)malloc(sizeof(WindowPropRec));
  p->name = (name<(void*)65536) ? (char *)name : strdup(name);
  p->data = val; p->_next=m_props; m_props=p;
  return TRUE;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent
{
  if (m_enabled)
  {
    SendMessage((HWND)self, WM_MOUSEACTIVATE, 0, 0);
    NSView* par=[self superview];
    if (par) SendMessage((HWND)par, WM_MOUSEACTIVATE, 0, 0);
    return YES;
  }
  return NO;
}

-(HMENU)swellGetMenu {   return m_menu; }
-(BOOL)swellHasBeenDestroyed { return !!m_hashaddestroy; }
-(void)swellSetMenu:(HMENU)menu {   
  if (m_menu) SWELL_SetMenuDestination(m_menu,NULL); // don't free m_menu, but at least make it not point to us anymore
  m_menu=menu; 
  if (m_menu) SWELL_SetMenuDestination(m_menu,(HWND)self);
}


- (id)initChild:(SWELL_DialogResourceIndex *)resstate Parent:(NSView *)parent dlgProc:(DLGPROC)dlgproc Param:(LPARAM)par
{
  NSRect contentRect=NSMakeRect(0,0,resstate ? resstate->width : 300,resstate ? resstate->height : 200);
  if (!(self = [super initWithFrame:contentRect])) return self;

  memset(m_access_cacheptrs,0,sizeof(m_access_cacheptrs));
  m_isdirty=3;
  m_glctx=NULL;
  m_enabled=TRUE;
  m_lastTopLevelOwner=NULL;
  m_dlgproc=NULL;
  m_wndproc=NULL;
  m_userdata=0;
  memset(&m_extradata,0,sizeof(m_extradata));
  m_tag=0;
  m_isfakerightmouse=0;
  m_hashaddestroy=false;
  m_menu=0;
  m_flip=0;
  m_supports_ddrop=0;
  m_paintctx_used=0;
  m_paintctx_hdc=0;
  m_props=0;
  
  m_titlestr[0]=0;
  
  m_wndproc=SwellDialogDefaultWindowProc;
  
  m_isopaque = !resstate || (resstate->windowTypeFlags&SWELL_DLG_WS_OPAQUE);
  m_flip = !resstate || (resstate->windowTypeFlags&SWELL_DLG_WS_FLIPPED);
  m_supports_ddrop = resstate && (resstate->windowTypeFlags&SWELL_DLG_WS_DROPTARGET);
  
  [self setHidden:YES];
  
  
  if ([parent isKindOfClass:[NSSavePanel class]]||[parent isKindOfClass:[NSOpenPanel class]])
  {
    [(NSSavePanel *)parent setAccessoryView:self];
    [self setHidden:NO];
  }
  else if ([parent isKindOfClass:[NSColorPanel class]])
  {
    [(NSColorPanel *)parent setAccessoryView:self];
    [self setHidden:NO];
  }  
  else if ([parent isKindOfClass:[NSFontPanel class]])
  {
    [(NSFontPanel *)parent setAccessoryView:self];
    [self setHidden:NO];
  }    
  else if ([parent isKindOfClass:[NSWindow class]])
  {
    [(NSWindow *)parent setContentView:self];
  }
  else
  {
    [parent addSubview:self];
  }
  if (resstate) resstate->createFunc((HWND)self,resstate->windowTypeFlags);
  
  if (resstate) m_dlgproc=dlgproc;  
  else if (dlgproc) m_wndproc=(WNDPROC)dlgproc;
  
  if (resstate && (resstate->windowTypeFlags&SWELL_DLG_WS_DROPTARGET))
  {
    [self registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType, NSFilesPromisePboardType, nil]];
  }
  
  if (!resstate)
    m_wndproc((HWND)self,WM_CREATE,0,par);
    
  if (m_dlgproc)
  {
    HWND hFoc=0;
    NSArray *ar=[self subviews];
    if (ar && [ar count]>0)
    {
      int x;
      for (x = 0; x < [ar count] && !hFoc; x ++)
      {
        NSView *v=[ar objectAtIndex:x];
        if (v && [v isKindOfClass:[NSScrollView class]]) v=[(NSScrollView *)v documentView];
        if (v && [v acceptsFirstResponder]) hFoc=(HWND)v;
      }
    }
    
    INT_PTR a;
    if ((a=m_dlgproc((HWND)self,WM_INITDIALOG,(WPARAM)hFoc,par)))
    {
      // set first responder to first item in window
      if (a == 0xbeef) hFoc = (HWND)self; // ret 0xbeef overrides to make the window itself focused (argh, need a cleaner way)
      if (hFoc) 
      {
        id wnd = [self window];
        if (wnd && [wnd firstResponder] != (id)hFoc) [wnd makeFirstResponder:(id)hFoc];
      }


      if (parent && [self window] == (NSWindow *)parent && [(id)parent isKindOfClass:[SWELL_ModelessWindow class]] && ![(NSWindow *)parent isVisible])
      {
        // on win32, if you do CreateDialog(), WM_INITDIALOG(ret=1), then ShowWindow(SW_SHOWNA), you get the
        // window brought to front. this simulates that, hackishly.
        ((SWELL_ModelessWindow *)parent)->m_wantInitialKeyWindowOnShow = true;
      }
    }
    else
    {
      // if top level dialog,always set default focus if it wasn't set
      // if this causes problems, change NSWindow to be SWELL_ModalDialog, as that would
      // only affect DialogBox() and not CreateDialog(), which might be preferable.
      if (hFoc && parent && [self window] == (NSWindow *)parent && [(id)parent isKindOfClass:[NSWindow class]]) 
      {
        id fr = [(NSWindow *)parent firstResponder];
        if (!fr || fr == self || fr == (id)parent) [(NSWindow *)parent makeFirstResponder:(id)hFoc];
        
      }
    }
    
    SWELL_DoDialogColorUpdates((HWND)self,m_dlgproc,false);
  }
  
//  if (!wasHid)
  //  [self setHidden:NO];
  
  return self;
}

-(void)setOpaque:(bool)isOpaque
{
  m_isopaque = isOpaque;
}

-(BOOL)isOpaque
{
  return m_isopaque;
}

- (void)setFrame:(NSRect)frameRect 
{
  [super setFrame:frameRect];
  if (m_wndproc&&!m_hashaddestroy) m_wndproc((HWND)self,WM_SIZE,0,0); 
  InvalidateRect(GetParent((HWND)self),NULL,FALSE);
} 

- (void)keyDown:(NSEvent *)theEvent
{
  int flag,code=SWELL_MacKeyToWindowsKey(theEvent,&flag);
  if (!m_wndproc || m_hashaddestroy || m_wndproc((HWND)self,WM_KEYDOWN,code,flag)==69) 
  {
    [super keyDown:theEvent];
  }
}

- (void)keyUp:(NSEvent *)theEvent
{
  int flag,code=SWELL_MacKeyToWindowsKey(theEvent,&flag);
  if (!m_wndproc || m_hashaddestroy || m_wndproc((HWND)self,WM_KEYUP,code,flag)==69) 
  {
    [super keyUp:theEvent];
  }
}

#if SWELL_CUT_OUT_COMPOSITING_MIDDLEMAN > 0 // not done yet

- (void)didAddSubview:(NSView *)subview
{
  m_isdirty|=2;
  NSView *view = [self superview];
  while (view)
  {
    if ([view isKindOfClass:[SWELL_hwndChild class]]) 
    {
      if (((SWELL_hwndChild *)view)->m_isdirty&2) break;
      ((SWELL_hwndChild *)view)->m_isdirty|=2;
    }
    view = [view superview];
  }
}
- (void)willRemoveSubview:(NSView *)subview
{
  m_isdirty|=3;
  [self setNeedsDisplay:YES];
  NSView *view = [self superview];
  while (view)
  {
    if ([view isKindOfClass:[SWELL_hwndChild class]]) 
    {
      if ((((SWELL_hwndChild *)view)->m_isdirty&3)==3) break;
      ((SWELL_hwndChild *)view)->m_isdirty|=3;
    }
    [view setNeedsDisplay:YES];
    view = [view superview];
  }
}

-(void)_recursiveDisplayRectIfNeededIgnoringOpacity:(NSRect)rect isVisibleRect:(BOOL)vr rectIsVisibleRectForView:(NSView*)v topView:(NSView *)v2
{

  
  
  // once we figure out how to get other controls to notify their parents that the view is dirty, we can enable this for 10.4
  // 10.5+ has some nice property where it goes up the hierarchy
  
//  NSLog(@"r:%@ vr:%d v=%p tv=%p self=%p %p\n",NSStringFromRect(rect),vr,v,v2,self, [[self window] contentView]);
  if (!useNoMiddleManCocoa() || ![self isOpaque] || [[self window] contentView] != self || [self isHiddenOrHasHiddenAncestor])
  {
    [super _recursiveDisplayRectIfNeededIgnoringOpacity:rect isVisibleRect:vr rectIsVisibleRectForView:v topView:v2];
    return;
  }
  
  if (!m_isdirty && ![self needsDisplay]) return;
  
  const NSRect *rlist=NULL;
  NSInteger rlistcnt=0;
  [self getRectsBeingDrawn:&rlist count:&rlistcnt];

  
  [self lockFocus];
  HDC hdc=SWELL_CreateGfxContext([NSGraphicsContext currentContext]);
  

  const bool twoPassMode = false; // true makes it draw non-opaque items over all window backgrounds, but opaque children going last (so native controls over groups, etc)
                                  // this is probably slower
  
  static WDL_PtrList<void> ndlist;
  int ndlist_oldsz=ndlist.GetSize();
  swellRenderOptimizely(twoPassMode?1:3,self,hdc,false,&ndlist,rlist,rlistcnt,0,0,true);
    
  while (ndlist.GetSize()>ndlist_oldsz+1)
  {
    NSView *v = (NSView *)ndlist.Get(ndlist.GetSize()-1);
    ndlist.Delete(ndlist.GetSize()-1);

    int flag = (int)(INT_PTR) ndlist.Get(ndlist.GetSize()-1);
    ndlist.Delete(ndlist.GetSize()-1);
    
    NSRect b = [v bounds];
    
    if (rlistcnt && !(flag&1))
    {
      int x;
      for(x=0;x<rlistcnt;x++)
      {
        NSRect r = rlist[x];
        r.origin.x--;
        r.origin.y--;
        r.size.width+=2;
        r.size.height+=2;
        r=[self convertRect:r toView:v];
        r=NSIntersectionRect(r,b);
        if (r.size.width>0 && r.size.height>0)
          [v displayRectIgnoringOpacity:r];
      }
    }
    else
      [v displayRectIgnoringOpacity:b];
    [v setNeedsDisplay:NO];
    [v release];
  }
  
  
  if (twoPassMode) swellRenderOptimizely(2,self,hdc,false,&ndlist,rlist,rlistcnt,0,0,true);
  SWELL_DeleteGfxContext(hdc);
  [self unlockFocus];
  [self setNeedsDisplay:NO];
  
}
#endif

-(void) drawRect:(NSRect)rect
{
  HDC hdc=SWELL_CreateGfxContext([NSGraphicsContext currentContext]);
  DrawSwellViewRectImpl(self,rect,hdc);
  SWELL_DeleteGfxContext(hdc);
  m_isdirty=0;

}

- (void)rightMouseDragged:(NSEvent *)theEvent
{
  if (!m_enabled) return;
  [self mouseDragged:theEvent];
}
- (void)otherMouseDragged:(NSEvent *)theEvent
{
  if (!m_enabled) return;
  [self mouseDragged:theEvent];
}

- (void)mouseDragged:(NSEvent *)theEvent
{ 
  if (!m_enabled) return;  

  SWELL_SendMouseMessage(self,WM_MOUSEMOVE,theEvent);
  if (SWELL_GetLastSetCursor()!=GetCursor()) SetCursor(SWELL_GetLastSetCursor());
}
- (void)mouseMoved:(NSEvent *)theEvent
{
  if (DelegateMouseMove(self,theEvent)) return;
  
  if (m_enabled) if (!GetCapture() || GetCapture()==(HWND)self) { 
    SWELL_SendMouseMessage(self,WM_MOUSEMOVE, theEvent);
  }
//  [super mouseMoved:theEvent];
}
- (void)mouseUp:(NSEvent *)theEvent
{
  if (!m_enabled) return;
	if (m_isfakerightmouse) [self rightMouseUp:theEvent];
  else SWELL_SendMouseMessage(self,WM_LBUTTONUP,theEvent);
}
- (void)scrollWheel:(NSEvent *)theEvent
{
  if (!m_enabled) return;
  if ([theEvent deltaY] != 0.0f)
  {
    SWELL_SendMouseMessage(self,WM_MOUSEWHEEL,theEvent);
  }  
  if ([theEvent deltaX] != 0.0f) 
  {
    SWELL_SendMouseMessage(self,WM_MOUSEHWHEEL,theEvent);
  }
}
- (void)mouseDown:(NSEvent *)theEvent
{
  SWELL_FinishDragDrop();
  if (!m_enabled) return;  
  
  m_isfakerightmouse=0;
  if (([theEvent modifierFlags] & NSControlKeyMask) && IsRightClickEmulateEnabled())
  {
    [self rightMouseDown:theEvent];
    if ([theEvent clickCount]<2) m_isfakerightmouse=1;
        return;
  }

  SWELL_SendMouseMessage(self,([theEvent clickCount]>1 ? WM_LBUTTONDBLCLK : WM_LBUTTONDOWN) ,theEvent);
}
- (void)rightMouseUp:(NSEvent *)theEvent
{
  if (!m_enabled) return;
  m_isfakerightmouse=0;
  SWELL_SendMouseMessage(self,WM_RBUTTONUP,theEvent);  
}
- (void)rightMouseDown:(NSEvent *)theEvent
{
  m_isfakerightmouse=0;
  if ([NSApp keyWindow] != [self window])
  {
    SetFocus((HWND)[self window]);
  }
  SWELL_SendMouseMessage(self,([theEvent clickCount]>1 ? WM_RBUTTONDBLCLK : WM_RBUTTONDOWN),theEvent); 
}  
- (void)otherMouseUp:(NSEvent *)theEvent
{
  if (!m_enabled) return;
  SWELL_SendMouseMessage(self,WM_MBUTTONUP,theEvent);  
}
- (void)otherMouseDown:(NSEvent *)theEvent
{
  if ([NSApp keyWindow] != [self window])
  {
    SetFocus((HWND)[self window]);
  }
  SWELL_SendMouseMessage(self,([theEvent clickCount]>1 ? WM_MBUTTONDBLCLK : WM_MBUTTONDOWN),theEvent); 
}  

// multitouch support

static void MakeGestureInfo(NSEvent* evt, GESTUREINFO* gi, HWND hwnd, int type)
{
  memset(gi, 0, sizeof(GESTUREINFO));
  gi->cbSize = sizeof(GESTUREINFO);
  
  gi->hwndTarget = hwnd;
  gi->dwID = type;
  
  NSWindow* wnd = [evt window];  
  NSPoint pt = [evt locationInWindow];
  pt = [wnd convertBaseToScreen:pt];  
  gi->ptsLocation.x = pt.x;
  gi->ptsLocation.y = pt.y; 
}

- (void)magnifyWithEvent:(NSEvent*)evt
{
  GESTUREINFO gi;
  MakeGestureInfo(evt, &gi, (HWND) self, GID_ZOOM);

  gi.dwFlags = GF_BEGIN;
  gi.ullArguments = 1024;  // arbitrary
  SendMessage((HWND)self, WM_GESTURE, 0, (LPARAM)&gi);

  gi.dwFlags = GF_END;    
  float z = [evt deltaZ]; // should be the same as 10.6 [evt magnification] 
  int a = (int)(1024.0f*z+0.5);
  if (!a) a = (z >= 0.0f ? 1 : -1);
  a += 1024;
  if (a < 512) a=512;
  else if (a > 2048) a=2048;
  gi.ullArguments = a;
  SendMessage((HWND)self, WM_GESTURE, gi.ullArguments, (LPARAM)&gi);      
}

- (void)swipeWithEvent:(NSEvent*)evt
{
  GESTUREINFO gi;
  MakeGestureInfo(evt, &gi, (HWND) self, GID_PAN);
  
  gi.dwFlags = GF_BEGIN;
  gi.ullArguments = 0; // for this gesture we only care about ptsLocation
  SendMessage((HWND)self, WM_GESTURE, 0, (LPARAM)&gi);
  
  gi.dwFlags = GF_END;    
  NSRect r = [self bounds];
  int dx=0;
  int dy=0;
  
  // for swipe events, deltaX/Y is either -1 or +1, convert to "one page"
  if ([evt deltaX] < 0.0f) dx = -r.size.width;
  else if ([evt deltaX] > 0.0f) dx = r.size.width;
  else if ([evt deltaY] < 0.0f) dy = r.size.height;
  else if ([evt deltaY] > 0.0f) dy = -r.size.height;  
  
  gi.ptsLocation.x += dx;
  gi.ptsLocation.y += dy;
  
  SendMessage((HWND)self, WM_GESTURE, gi.ullArguments, (LPARAM)&gi);   
}

-(void) rotateWithEvent:(NSEvent*)evt
{
  GESTUREINFO gi;
  MakeGestureInfo(evt, &gi, (HWND) self, GID_ROTATE);
  
  gi.dwFlags = GF_BEGIN;
  gi.ullArguments = 0;  // Windows sends the absolute starting rotation as the first message, Mac doesn't
  SendMessage((HWND)self, WM_GESTURE, 0, (LPARAM)&gi);
  
  gi.dwFlags = GF_END;    
  float z = [evt rotation];
  int i = (int)32767.0f*z/60.0f;
  if (!i) i = (z >= 0.0f ? 1 : -1);
  i += 32767;
  if (i < 0) i=0;
  else if (i > 65535) i=65535;
  gi.ullArguments = i;  
  SendMessage((HWND)self, WM_GESTURE, i, (LPARAM)&gi);   
}


- (const char *)onSwellGetText { return m_titlestr; }
-(void)onSwellSetText:(const char *)buf { lstrcpyn_safe(m_titlestr,buf,sizeof(m_titlestr)); }


// source-side drag/drop, only does something if source called SWELL_InitiateDragDrop while handling mouseDown
- (NSArray*) namesOfPromisedFilesDroppedAtDestination:(NSURL*) dropdestination
{
  NSArray* SWELL_DoDragDrop(NSURL*);
  return SWELL_DoDragDrop(dropdestination); 
}


/*
- (BOOL)becomeFirstResponder 
{
  if (!m_enabled) return NO;
  HWND foc=GetFocus();
  if (![super becomeFirstResponder]) return NO;
  [self onSwellMessage:WM_ACTIVATE p1:WA_ACTIVE p2:(LPARAM)foc];
  return YES;
}

- (BOOL)resignFirstResponder
{
  HWND foc=GetFocus();
  if (![super resignFirstResponder]) return NO;
  [self onSwellMessage:WM_ACTIVATE p1:WA_INACTIVE p2:(LPARAM)foc];
  return YES;
}
*/

- (BOOL)acceptsFirstResponder 
{
  if (m_enabled)
  {
    if (GetFocus() != (HWND)self)
    {
      SendMessage((HWND)self, WM_MOUSEACTIVATE, 0, 0);
    }
    return YES;
  }
  return NO;
}

-(void)swellSetExtendedStyle:(LONG)st
{
  if (st&WS_EX_ACCEPTFILES) m_supports_ddrop=true;
  else m_supports_ddrop=false;
}
-(LONG)swellGetExtendedStyle
{
  LONG ret=0;
  if (m_supports_ddrop) ret|=WS_EX_ACCEPTFILES;
  return ret;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender 
{
  if (!m_supports_ddrop) return NSDragOperationNone;

  if (SWELL_DDrop_onDragEnter)
  {
    HANDLE h = (HANDLE)[self swellExtendedDragOp:sender retGlob:YES];
    if (h)
    {
      NSPoint p=[[self window] convertBaseToScreen:[sender draggingLocation]];
      POINT pt={(int)(p.x+0.5),(int)(p.y+0.5)};
      SWELL_DDrop_onDragEnter(h,pt);
      GlobalFree(h);
    }
  }
    
  return NSDragOperationGeneric;
}
- (BOOL) wantsPeriodicDraggingUpdates
{
  return NO;
}
- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender 
{
  if (!m_supports_ddrop) return NSDragOperationNone;

  if (SWELL_DDrop_onDragOver)
  {
    NSPoint p=[[self window] convertBaseToScreen:[sender draggingLocation]];
    POINT pt={(int)(p.x+0.5),(int)(p.y+0.5)};
    SWELL_DDrop_onDragOver(pt);
  }
  
  return NSDragOperationGeneric;
  
} 
- (void)draggingExited:(id <NSDraggingInfo>)sender
{
  if (m_supports_ddrop && SWELL_DDrop_onDragLeave) SWELL_DDrop_onDragLeave();
}

-(HANDLE)swellExtendedDragOp:(id <NSDraggingInfo>)sender retGlob:(BOOL)retG
{
  if (!m_supports_ddrop) return 0;
  
  NSPasteboard *pboard;
  NSDragOperation sourceDragMask;
  sourceDragMask = [sender draggingSourceOperationMask];
  pboard = [sender draggingPasteboard];
 
  enum { PB_FILEREF=1, PB_FILEPROMISE };
  int pbtype = 0;
  if ([[pboard types] containsObject:NSFilenamesPboardType]) pbtype |= PB_FILEREF;
  if ([[pboard types] containsObject:NSFilesPromisePboardType]) pbtype |= PB_FILEPROMISE;
  if (!pbtype) return 0; 
 
  int sz=sizeof(DROPFILES);

  bool maketmpfn = false;
  NSArray *files = 0;
  if (pbtype&PB_FILEREF) 
  {
    files = [pboard propertyListForType:NSFilenamesPboardType]; 
  }
  else if (pbtype&PB_FILEPROMISE) 
  {
    NSArray* exts = [pboard propertyListForType:NSFilesPromisePboardType];  // just the file extensions
    if (retG) 
    {
      files = exts;
      maketmpfn = true;
    }
    else if (SWELL_DDrop_getDroppedFileTargetPath)
    {
      char ext[256];
      ext[0] = 0;
      if ([exts objectAtIndex:0]) SWELL_CFStringToCString([exts objectAtIndex:0], ext, sizeof(ext));

      const char* droppath = SWELL_DDrop_getDroppedFileTargetPath(ext);
      if (!droppath || !droppath[0]) droppath = "/tmp/";
      NSString* pathstr = (NSString*)SWELL_CStringToCFString(droppath);
      NSURL* dest = [NSURL fileURLWithPath:pathstr];
      
      files = [sender namesOfPromisedFilesDroppedAtDestination:dest]; // tells the drag source to create the files
      
      if ([files count])
      {
        NSMutableArray* paths=[NSMutableArray arrayWithCapacity:[files count]];
        int i;
        for (i=0; i < [files count]; ++i)
        {
          NSString* fn=[files objectAtIndex:i];
          if (fn) 
          {
            [paths addObject:[pathstr stringByAppendingPathComponent:fn]];
          }
        }
        files=paths;
      }
      
      [pathstr release];
    }      
  }
  if (!files) return 0;
  
  int x;
  for (x = 0; x < [files count]; x ++)
  {
    NSString *sv=[files objectAtIndex:x]; 
    if (sv)
    {
      char text[4096];
      text[0]=0;
      SWELL_CFStringToCString(sv,text,sizeof(text));
      sz+=strlen(text)+1;
      if (maketmpfn) sz += strlen("tmp.");
    }
  }

  NSPoint tpt = [self convertPoint:[sender draggingLocation] fromView:nil];  
  
  HANDLE gobj=GlobalAlloc(0,sz+1);
  DROPFILES *df=(DROPFILES*)gobj;
  df->pFiles=sizeof(DROPFILES);
  df->pt.x = (int)(tpt.x+0.5);
  df->pt.y = (int)(tpt.y+0.5);
  df->fNC = FALSE;
  df->fWide = FALSE;
  char *pout = (char *)(df+1);
  for (x = 0; x < [files count]; x ++)
  {
    NSString *sv=[files objectAtIndex:x]; 
    if (sv)
    {
      char text[4096];
      text[0]=0;      
      SWELL_CFStringToCString(sv,text,sizeof(text));      
      if (maketmpfn)
      {
        strcpy(pout, "tmp.");
        pout += strlen("tmp.");
      }
      strcpy(pout,text);
      pout+=strlen(pout)+1;
    }
  }
  *pout=0;
  
  if (!retG)
  {
    [self onSwellMessage:WM_DROPFILES p1:(WPARAM)gobj p2:0];
    GlobalFree(gobj);
  }
  
  return gobj;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
  if (m_supports_ddrop && SWELL_DDrop_onDragLeave) SWELL_DDrop_onDragLeave();

  HWND cv = NULL; // view to disable "setwindowrepre()" for
  
  id dragsrc = [sender draggingSource];
  if ([dragsrc isKindOfClass:[NSView class]])
  {
    if ([(NSView *)dragsrc window] == [self window]) // this means we're likely dragging from the titlebar, so we gotta disable setwindowrepre cause cocoa sucks
    {
      cv = (HWND) [[self window] contentView];
    }
  }
   
  if (cv) SetProp(cv,"SWELL_DisableWindowRepre",(HANDLE)TRUE);
  
  NSView *v=[self hitTest:[[self superview] convertPoint:[sender draggingLocation] fromView:nil]];
  if (v && [v isDescendantOf:self])
  {
    while (v && v!=self)
    {
      if ([v respondsToSelector:@selector(swellExtendedDragOp:retGlob:)])
        if ([(SWELL_hwndChild *)v swellExtendedDragOp:sender retGlob:NO]) 
        {
          if (cv) RemoveProp(cv,"SWELL_DisableWindowRepre");
          return YES;
        }
      v=[v superview];
    }
  }
  
  BOOL ret=!![self swellExtendedDragOp:sender retGlob:NO];
  if (cv) RemoveProp(cv,"SWELL_DisableWindowRepre");
  return ret;
}

-(unsigned int)swellCreateWindowFlags
{
  return m_create_windowflags;
}




// NSAccessibility


- (id)accessibilityHitTest:(NSPoint)point
{
  id ret = NULL;
  id use_obj = NULL;
  SendMessage((HWND)self,WM_GETOBJECT,0x1001,(LPARAM)&use_obj);
  if (use_obj)
  {
    ret = [use_obj accessibilityHitTest:point];
    if (ret == use_obj && [ret accessibilityIsIgnored]) ret = NULL;
  }

  if (!ret) ret = [super accessibilityHitTest:point];
  return ret;
}
- (id)accessibilityFocusedUIElement
{
  id use_obj = NULL, ret = NULL;
  SendMessage((HWND)self,WM_GETOBJECT,0x1001,(LPARAM)&use_obj);
  if (use_obj)
  {
    ret = [use_obj accessibilityFocusedUIElement];
    if (ret == use_obj) ret=  NULL;
  }
  if (!ret) ret = [super accessibilityFocusedUIElement];
  return ret;
}

- (id)accessibilityAttributeValue:(NSString *)attribute
{
  id ret = [super accessibilityAttributeValue:attribute];
  int wo=0;
  if ([attribute isEqual:NSAccessibilityChildrenAttribute] || (wo = !![attribute isEqual:NSAccessibilityVisibleChildrenAttribute]))
  {
    id *cp = wo ? m_access_cacheptrs+3 : m_access_cacheptrs;
    id use_obj = NULL;
    SendMessage((HWND)self,WM_GETOBJECT,0x1001,(LPARAM)&use_obj);
    if (use_obj)
    {
      if (cp[0] && cp[1] && use_obj == cp[2] && (ret==cp[1] || [ret isEqualToArray:cp[1]])) return cp[0];

      NSArray *ar=NULL;
      if (ret && [ret count])
      {
        ar = [NSMutableArray arrayWithArray:ret];
        [(NSMutableArray *)ar addObject:use_obj];        
      }
      else ar = [NSArray arrayWithObject:use_obj];
      
      int x;
      for (x=0;x<3;x++) if (cp[x]) { [cp[x] release]; cp[x]=0; }

      //cp[1]=ret;
      //cp[2]=use_obj;

      ret = NSAccessibilityUnignoredChildren(ar);
      //cp[0]=ret;

      for (x=0;x<3;x++) if (cp[x]) [cp[x] retain];

      return ret;
    }  
    int x;
    for (x=0;x<3;x++) if (cp[x]) { [cp[x] release]; cp[x]=0; }
  }
  
  return ret;
}
// Return YES if the UIElement doesn't show up to the outside world - i.e. its parent should return the UIElement's children as its own - cutting the UIElement out. E.g. NSControls are ignored when they are single-celled.
- (BOOL)accessibilityIsIgnored
{
  if (![[self subviews] count])
  {
    id use_obj = NULL;
    SendMessage((HWND)self,WM_GETOBJECT,0x1001,(LPARAM)&use_obj);
  
    if (use_obj)
    {
      return YES;
    }
  }
  return [super accessibilityIsIgnored];
}






@end





static HWND last_key_window;


#define SWELLDIALOGCOMMONIMPLEMENTS_WND(ISMODAL) \
-(BOOL)acceptsFirstResponder { return m_enabled?YES:NO; } \
- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent {	return m_enabled?YES:NO; } \
- (void)setFrame:(NSRect)frameRect display:(BOOL)displayFlag \
{ \
  [super setFrame:frameRect display:displayFlag]; \
  if((int)frameRect.size.width != (int)lastFrameSize.width || (int)frameRect.size.height != (int)lastFrameSize.height) { \
    SWELL_hwndChild *hc = (SWELL_hwndChild*)[self contentView]; \
    sendSwellMessage(hc,WM_SIZE,0,0); \
    if ([hc isOpaque]) InvalidateRect((HWND)hc,NULL,FALSE); \
    lastFrameSize=frameRect.size; \
   } \
} \
- (void)windowDidMove:(NSNotification *)aNotification { \
    NSRect f=[self frame]; \
    sendSwellMessage([self contentView], WM_MOVE,0, MAKELPARAM((int)f.origin.x,(int)f.origin.y)); \
} \
- (BOOL)accessibilityIsIgnored \
{ \
  if (!([self styleMask] & NSTitledWindowMask) && ![[[self contentView] subviews] count]) return YES; \
  return [super accessibilityIsIgnored]; \
} \
-(void)swellDoDestroyStuff \
{ \
  if (last_key_window==(HWND)self) last_key_window=0; \
      OwnedWindowListRec *p=m_ownedwnds; m_ownedwnds=0; \
        while (p) \
        { \
          OwnedWindowListRec *next=p->_next;  \
            DestroyWindow((HWND)p->hwnd); \
              free(p); p=next;  \
        } \
  if (last_key_window==(HWND)self) last_key_window=0; \
  if (m_owner) { \
     [(SWELL_ModelessWindow*)m_owner swellRemoveOwnedWindow:self]; \
     if ([NSApp keyWindow] == self) [(SWELL_ModelessWindow*)m_owner makeKeyWindow]; \
     m_owner=0;  \
   } \
} \
-(void)dealloc \
{ \
  [self swellDoDestroyStuff]; \
  [super dealloc]; \
} \
- (void)swellDestroyAllOwnedWindows \
{ \
  OwnedWindowListRec *p=m_ownedwnds; m_ownedwnds=0; \
    while (p) \
    { \
      OwnedWindowListRec *next=p->_next;  \
        DestroyWindow((HWND)p->hwnd); \
          free(p); p=next;  \
    } \
} \
- (void)resignKeyWindow { \
  [super resignKeyWindow]; \
  if (g_swell_terminating) return; \
  sendSwellMessage([self contentView],WM_ACTIVATE,WA_INACTIVE,0); \
  last_key_window=(HWND)self; \
} \
-(void)becomeKeyWindow \
{ \
  [super becomeKeyWindow]; \
  if (g_swell_terminating) return; \
  NSView *foc=last_key_window && IsWindow(last_key_window) ? [(NSWindow *)last_key_window contentView] : 0; \
  HMENU menu=0; \
  if (foc && [foc respondsToSelector:@selector(swellHasBeenDestroyed)] && [(SWELL_hwndChild*)foc swellHasBeenDestroyed]) foc=NULL; \
  NSView *cv = [self contentView];  \
  if (!cv || ![cv respondsToSelector:@selector(swellHasBeenDestroyed)] || ![(SWELL_hwndChild*)cv swellHasBeenDestroyed])  { \
    if ([cv respondsToSelector:@selector(swellGetMenu)]) menu = [(SWELL_hwndChild*)cv swellGetMenu]; \
    if (!menu) menu=ISMODAL && g_swell_defaultmenumodal ? g_swell_defaultmenumodal : g_swell_defaultmenu; \
    if (menu && menu != (HMENU)[NSApp mainMenu] && !g_swell_terminating) [NSApp setMainMenu:(NSMenu *)menu]; \
    sendSwellMessage(cv,WM_ACTIVATE,WA_ACTIVE,(LPARAM)foc); \
    sendSwellMessage(cv,WM_MOUSEACTIVATE,0,0); \
  } \
} \
-(BOOL)windowShouldClose:(id)sender \
{ \
  NSView *v=[self contentView]; \
  if ([v respondsToSelector:@selector(onSwellMessage:p1:p2:)]) \
    if (![(SWELL_hwndChild*)v onSwellMessage:WM_CLOSE p1:0 p2:0]) \
      [(SWELL_hwndChild*)v onSwellMessage:WM_COMMAND p1:IDCANCEL p2:0]; \
  return NO; \
} \
- (BOOL)canBecomeKeyWindow {   return !!m_enabled && !g_swell_terminating; } \
- (void **)swellGetOwnerWindowHead { return (void **)&m_ownedwnds; } \
- (void)swellAddOwnedWindow:(NSWindow*)wnd \
{ \
    OwnedWindowListRec *p=m_ownedwnds; \
    while (p) { \
      if (p->hwnd == wnd) return; \
        p=p->_next; \
    } \
    p=(OwnedWindowListRec*)malloc(sizeof(OwnedWindowListRec)); \
    p->hwnd=wnd; p->_next=m_ownedwnds; m_ownedwnds=p; \
    if ([wnd respondsToSelector:@selector(swellSetOwner:)]) [(SWELL_ModelessWindow*)wnd swellSetOwner:self];  \
    if (SWELL_owned_windows_levelincrease) if ([wnd isKindOfClass:[NSWindow class]]) \
    { \
      int extra = [wnd isKindOfClass:[SWELL_ModelessWindow class]] ? ((SWELL_ModelessWindow *)wnd)->m_wantraiseamt : 0; \
      if ([NSApp isActive]) [wnd setLevel:[self level]+1+extra];  \
    } \
}  \
- (void)swellRemoveOwnedWindow:(NSWindow *)wnd \
{ \
  OwnedWindowListRec *p=m_ownedwnds, *lp=NULL; \
    while (p) { \
      if (p->hwnd == wnd) { \
        if (lp) lp->_next=p->_next; \
          else m_ownedwnds=p->_next; \
            free(p); \
              return; \
      } \
      lp=p; \
        p=p->_next; \
    } \
} \
- (void)swellResetOwnedWindowLevels { \
  if (SWELL_owned_windows_levelincrease) { OwnedWindowListRec *p=m_ownedwnds; \
  bool active =  [NSApp isActive]; \
  int l=[self level]+!!active; \
    while (p) { \
      if (p->hwnd) { \
        int extra = active && [(id)p->hwnd isKindOfClass:[SWELL_ModelessWindow class]] ? ((SWELL_ModelessWindow *)p->hwnd)->m_wantraiseamt : 0; \
        [(NSWindow *)p->hwnd setLevel:l+extra]; \
        if ([(id)p->hwnd respondsToSelector:@selector(swellResetOwnedWindowLevels)]) \
          [(id)p->hwnd swellResetOwnedWindowLevels]; \
      } \
      p=p->_next; \
    } \
  } \
} \
- (void)swellSetOwner:(id)owner { m_owner=owner; } \
- (id)swellGetOwner { return m_owner; }  \
- (NSSize)minSize \
{ \
  MINMAXINFO mmi={0}; \
  NSSize minsz=(NSSize)[super minSize]; \
  mmi.ptMinTrackSize.x=(int)minsz.width; mmi.ptMinTrackSize.y=(int)minsz.height; \
  sendSwellMessage([self contentView],WM_GETMINMAXINFO,0,(LPARAM)&mmi); \
  minsz.width=mmi.ptMinTrackSize.x; minsz.height=mmi.ptMinTrackSize.y; \
  return minsz; \
} \
- (NSSize)maxSize \
{ \
  MINMAXINFO mmi={0}; \
  NSSize maxsz=(NSSize)[super maxSize]; NSSize tmp=maxsz;\
  if (tmp.width<1)tmp.width=1; else if (tmp.width > 1000000.0) tmp.width=1000000.0; \
  if (tmp.height<1)tmp.height=1; else if (tmp.height > 1000000.0) tmp.height=1000000.0; \
  mmi.ptMaxTrackSize.x=(int)tmp.width; mmi.ptMaxTrackSize.y=(int)tmp.height; \
  sendSwellMessage([self contentView], WM_GETMINMAXINFO, 0, (LPARAM)&mmi); \
  if (mmi.ptMaxTrackSize.x < 1000000) maxsz.width=mmi.ptMaxTrackSize.x; \
  if (mmi.ptMaxTrackSize.y < 1000000) maxsz.height=mmi.ptMaxTrackSize.y; \
  return maxsz; \
} \



#define INIT_COMMON_VARS \
  m_enabled=TRUE; \
  m_owner=0; \
  m_ownedwnds=0; 


#if 0
#define DOWINDOWMINMAXSIZES(ch) \
{ \
  MINMAXINFO mmi={0}; \
    NSSize minsz=(NSSize)[super contentMinSize]; \
      mmi.ptMinTrackSize.x=(int)minsz.width; mmi.ptMinTrackSize.y=(int)minsz.height; \
        sendSwellMessage(ch,WM_GETMINMAXINFO,0,(LPARAM)&mmi); \
          minsz.width=mmi.ptMinTrackSize.x; minsz.height=mmi.ptMinTrackSize.y; \
            [super setContentMinSize:minsz];  \
}

#endif

static void GetInitialWndPos(HWND owner, int h, int* x, int* y)
{
  RECT r;
  if (owner) GetWindowRect(owner, &r);
  else SWELL_GetViewPort(&r, 0, false);
  *x = r.left+50;
  *y = r.bottom-h-100;
}


@implementation SWELL_ModelessWindow : NSWindow

SWELLDIALOGCOMMONIMPLEMENTS_WND(0)


- (id)initModelessForChild:(HWND)child owner:(HWND)owner styleMask:(unsigned int)smask
{
  INIT_COMMON_VARS
  m_wantInitialKeyWindowOnShow=0;
  m_wantraiseamt=0;
  lastFrameSize.width=lastFrameSize.height=0.0f;
    
  NSRect cr=[(NSView *)child bounds];
  
  int wx, wy;
  GetInitialWndPos(owner, cr.size.height, &wx, &wy); 
  NSRect contentRect=NSMakeRect(wx,wy,cr.size.width,cr.size.height);
  if (!(self = [super initWithContentRect:contentRect styleMask:smask backing:NSBackingStoreBuffered defer:NO])) return self;

  [self setDelegate:(id)self];
  [self disableCursorRects];
  [self setAcceptsMouseMovedEvents:YES];
  [self setContentView:(NSView *)child];
  [self useOptimizedDrawing:YES];
  updateWindowCollection(self);
    
  if (owner && [(id)owner respondsToSelector:@selector(swellAddOwnedWindow:)])
  {
    [(id)owner swellAddOwnedWindow:self]; 
  }
  else if (owner && [(id)owner isKindOfClass:[NSView class]])
  {
    NSWindow *w=[(id)owner window];
    if (w && [w respondsToSelector:@selector(swellAddOwnedWindow:)])
    {
      [(SWELL_ModelessWindow*)w swellAddOwnedWindow:self]; 
    }
  }
    
  [self display];
  return self;
}

- (id)initModeless:(SWELL_DialogResourceIndex *)resstate Parent:(HWND)parent dlgProc:(DLGPROC)dlgproc Param:(LPARAM)par outputHwnd:(HWND *)hwndOut forceStyles:(unsigned int)smask
{
  INIT_COMMON_VARS
  m_wantInitialKeyWindowOnShow=0;
  m_wantraiseamt=0;

  lastFrameSize.width=lastFrameSize.height=0.0f;
  
  int w = (resstate ? resstate->width : 10);
  int h = (resstate ? resstate->height : 10);
  
  int wx, wy;
  GetInitialWndPos(parent, h, &wx, &wy);  
  NSRect contentRect=NSMakeRect(wx,wy,w,h);
  int sf=smask;
  
  if (resstate)
  {
    sf |= NSTitledWindowMask|NSMiniaturizableWindowMask|NSClosableWindowMask;
    if (resstate->windowTypeFlags&SWELL_DLG_WS_RESIZABLE) sf |= NSResizableWindowMask;
  }
  
  if (!(self = [super initWithContentRect:contentRect styleMask:sf backing:NSBackingStoreBuffered defer:NO])) return self;
  
  [self disableCursorRects];
  [self setAcceptsMouseMovedEvents:YES];
  [self useOptimizedDrawing:YES];
  [self setDelegate:(id)self];
  updateWindowCollection(self);
  
  if (resstate&&resstate->title) SetWindowText((HWND)self, resstate->title);
  
  
  if (parent && [(id)parent respondsToSelector:@selector(swellAddOwnedWindow:)])
  {
    [(id)parent swellAddOwnedWindow:self]; 
  }
  else if (parent && [(id)parent isKindOfClass:[NSView class]])
  {
    NSWindow *w=[(id)parent window];
    if (w && [w respondsToSelector:@selector(swellAddOwnedWindow:)])
    {
      [(SWELL_ModelessWindow*)w swellAddOwnedWindow:self]; 
    }
  }
  
  [self retain]; // in case WM_INITDIALOG goes and releases us
  
  SWELL_hwndChild *ch=[[SWELL_hwndChild alloc] initChild:resstate Parent:(NSView *)self dlgProc:dlgproc Param:par];       // create a new child view class
  ch->m_create_windowflags=sf;
  *hwndOut = (HWND)ch;
 
  [ch release];

  [self display];
  [self release]; // matching retain above
  
  return self;
}
-(NSInteger)level
{
  //if (SWELL_owned_windows_levelincrease) return NSNormalWindowLevel;
  return [super level];
}

#if SWELL_CUT_OUT_COMPOSITING_MIDDLEMAN > 1
-(void) displayIfNeeded
{
  if (![[self contentView] isOpaque])
  {
    [super displayIfNeeded];
  }
  else
  {
  //  NSThemeFrame
    if ([self viewsNeedDisplay])
    {
      [[self contentView] _recursiveDisplayRectIfNeededIgnoringOpacity:NSMakeRect(0,0,0,0) isVisibleRect:YES rectIsVisibleRectForView:[self contentView] topView:[self contentView]];
      [self setViewsNeedDisplay:NO];
      [self flushWindow];
    }

  }
}
#endif

@end




@implementation SWELL_ModalDialog : NSPanel

SWELLDIALOGCOMMONIMPLEMENTS_WND(1)



- (id)initDialogBox:(SWELL_DialogResourceIndex *)resstate Parent:(HWND)parent dlgProc:(DLGPROC)dlgproc Param:(LPARAM)par
{
  m_rv=0;
  m_hasrv=false;
  INIT_COMMON_VARS
  
  NSRect contentRect=NSMakeRect(0,0,resstate->width,resstate->height);
  unsigned int sf=(NSTitledWindowMask|NSClosableWindowMask|((resstate->windowTypeFlags&SWELL_DLG_WS_RESIZABLE)? NSResizableWindowMask : 0));
  if (!(self = [super initWithContentRect:contentRect styleMask:sf backing:NSBackingStoreBuffered defer:NO])) return self;

  [self setAcceptsMouseMovedEvents:YES];
  [self disableCursorRects];
  [self useOptimizedDrawing:YES];
  [self setDelegate:(id)self];
  updateWindowCollection(self);

  if (parent && [(id)parent respondsToSelector:@selector(swellAddOwnedWindow:)])
  {
    [(id)parent swellAddOwnedWindow:self]; 
  }
  else if (parent && [(id)parent isKindOfClass:[NSView class]])
  {
    NSWindow *w=[(id)parent window];
    if (w && [w respondsToSelector:@selector(swellAddOwnedWindow:)])
    {
      [(SWELL_ModelessWindow*)w swellAddOwnedWindow:self]; 
    }
  }
  if (resstate&&resstate->title) SetWindowText((HWND)self, resstate->title);
  
  SWELL_hwndChild *ch=[[SWELL_hwndChild alloc] initChild:resstate Parent:(NSView *)self dlgProc:dlgproc Param:par];       // create a new child view class
  ch->m_create_windowflags=sf;
  [ch setHidden:NO];
//  DOWINDOWMINMAXSIZES(ch)
  [ch release];

  [self setHidesOnDeactivate:NO];
  [self display];
  
  return self;
}


-(void)swellSetModalRetVal:(int)r
{
  m_hasrv=true;
  m_rv=r;
}
-(int)swellGetModalRetVal
{
  return m_rv;
}
-(bool)swellHasModalRetVal
{
  return m_hasrv;
}

@end

void EndDialog(HWND wnd, int ret)
{   
  if (!wnd) return;
  
  NSWindow *nswnd=NULL;
  NSView *nsview = NULL;
  if ([(id)wnd isKindOfClass:[NSView class]])
  {
    nsview = (NSView *)wnd;
    nswnd = [nsview window];
  }
  else if ([(id)wnd isKindOfClass:[NSWindow class]])
  {
    nswnd = (NSWindow *)wnd;
    nsview = [nswnd contentView];
  }
  if (!nswnd) return;
   
  if ([nswnd respondsToSelector:@selector(swellSetModalRetVal:)])
    [(SWELL_ModalDialog*)nswnd swellSetModalRetVal:ret];

  if ([NSApp modalWindow] == nswnd)
  {   
    sendSwellMessage(nsview,WM_DESTROY,0,0);
    
    NSEvent *evt=[NSApp currentEvent];
    if (evt && [evt window] == nswnd)
    {
      [NSApp stopModal];
    }
    
    [NSApp abortModal]; // always call this, otherwise if running in runModalForWindow: it can often require another even tto come through before things continue
    
    [nswnd close];
  }
}


int SWELL_DialogBox(SWELL_DialogResourceIndex *reshead, const char *resid, HWND parent,  DLGPROC dlgproc, LPARAM param)
{
  SWELL_DialogResourceIndex *p=resById(reshead,resid);
  if (!p||(p->windowTypeFlags&SWELL_DLG_WS_CHILD)) return -1;
  SWELL_ModalDialog *box = [[SWELL_ModalDialog alloc] initDialogBox:p Parent:parent dlgProc:dlgproc Param:param];      
     
  if (!box) return -1;
  
  if ([box swellHasModalRetVal]) // detect EndDialog() in WM_INITDIALOG
  {
    int ret=[box swellGetModalRetVal];
    sendSwellMessage([box contentView],WM_DESTROY,0,0);
    [box release];
    return ret;
  }
    
  if (0 && ![NSApp isActive]) // using this enables better background processing (i.e. if the app isnt active it still runs)
  {
    [NSApp activateIgnoringOtherApps:YES];
    NSModalSession session = [NSApp beginModalSessionForWindow:box];
    for (;;) 
    {
      if ([NSApp runModalSession:session] != NSRunContinuesResponse) break;
      Sleep(1);
    }
    [NSApp endModalSession:session];
  }
  else
  {
    [NSApp runModalForWindow:box];
  }
  int ret=[box swellGetModalRetVal];
  [box release];
  return ret;
}

HWND SWELL_CreateModelessFrameForWindow(HWND childW, HWND ownerW, unsigned int windowFlags)
{
    SWELL_ModelessWindow *ch=[[SWELL_ModelessWindow alloc] initModelessForChild:childW owner:ownerW styleMask:windowFlags];
    return (HWND)ch;
}


HWND SWELL_CreateDialog(SWELL_DialogResourceIndex *reshead, const char *resid, HWND parent, DLGPROC dlgproc, LPARAM param)
{
  unsigned int forceStyles=0;
  if ((((INT_PTR)resid)&~0xf)==0x400000)
  {
    int a = (int)(INT_PTR)resid;
    forceStyles = NSTitledWindowMask|NSMiniaturizableWindowMask|NSClosableWindowMask;
    if (a&1) forceStyles|=NSResizableWindowMask;
    if (a&2) forceStyles&=~NSMiniaturizableWindowMask;
    if (a&4) forceStyles&=~NSClosableWindowMask;
    resid=NULL;
  }
  SWELL_DialogResourceIndex *p=resById(reshead,resid);
  if (!p&&resid) return 0;
  
  NSView *parview=NULL;
  if (parent && ([(id)parent isKindOfClass:[NSView class]] || 
                 [(id)parent isKindOfClass:[NSSavePanel class]] || 
                 [(id)parent isKindOfClass:[NSOpenPanel class]] ||
                 [(id)parent isKindOfClass:[NSColorPanel class]] || 
                 [(id)parent isKindOfClass:[NSFontPanel class]]
                 )) parview=(NSView *)parent;
  else if (parent && [(id)parent isKindOfClass:[NSWindow class]])  parview=(NSView *)[(id)parent contentView];
  
  if ((!p || (p->windowTypeFlags&SWELL_DLG_WS_CHILD)) && parview)
  {
    SWELL_hwndChild *ch=[[SWELL_hwndChild alloc] initChild:p Parent:parview dlgProc:dlgproc Param:param];       // create a new child view class
    ch->m_create_windowflags=(NSTitledWindowMask|NSMiniaturizableWindowMask|NSClosableWindowMask|NSResizableWindowMask);
    [ch release];
    return (HWND)ch;
  }
  else
  {
    HWND h=NULL;
    [[SWELL_ModelessWindow alloc] initModeless:p Parent:parent dlgProc:dlgproc Param:param outputHwnd:&h forceStyles:forceStyles];
    return h;
  }
  
  return 0;
}


HMENU SWELL_GetDefaultWindowMenu() { return g_swell_defaultmenu; }
void SWELL_SetDefaultWindowMenu(HMENU menu)
{
  g_swell_defaultmenu=menu;
}
HMENU SWELL_GetDefaultModalWindowMenu() 
{ 
  return g_swell_defaultmenumodal; 
}
void SWELL_SetDefaultModalWindowMenu(HMENU menu)
{
  g_swell_defaultmenumodal=menu;
}



SWELL_DialogResourceIndex *SWELL_curmodule_dialogresource_head; // this eventually will go into a per-module stub file


#import <Carbon/Carbon.h>


#if 0
static void PrintAllHIViews(HIViewRef f, const char *bla)
{
  char tmp[4096];
  sprintf(tmp,"%s:%08x",bla,f);
  
  HIRect r;
  HIViewGetFrame(f,&r);
  printf("%s beg %f %f %f %f\n",tmp,r.origin.x,r.origin.y,r.size.width, r.size.height);
  HIViewRef a=HIViewGetFirstSubview(f);
  while (a)
  {
    PrintAllHIViews(a,tmp);
    a=HIViewGetNextView(a);  
  }
  printf("%s end\n",tmp);
}
#endif

#ifndef __LP64__
// carbon event handler for carbon-in-cocoa
OSStatus CarbonEvtHandler(EventHandlerCallRef nextHandlerRef, EventRef event, void* userdata)
{
  SWELL_hwndCarbonHost* _this = (SWELL_hwndCarbonHost*)userdata;
  UInt32 evtkind = GetEventKind(event);

  switch (evtkind)
  {
    case kEventWindowActivated:
      if (!g_swell_terminating) [NSApp setMainMenu:nil];
    break;
    
    case kEventWindowGetClickActivation: 
    {
      ClickActivationResult car = kActivateAndHandleClick;
      SetEventParameter(event, kEventParamClickActivation, typeClickActivationResult, sizeof(ClickActivationResult), &car);
    }
    break;
    
    case kEventWindowHandleDeactivate:
    {
      if (_this)
      {
        WindowRef wndref = (WindowRef)[_this->m_cwnd windowRef];
        if (wndref) ActivateWindow(wndref, true);
      }
    }
    break;
  
    case kEventControlBoundsChanged:
    {
      if (_this && !_this->m_whileresizing)
      {
        Rect prevr, curr;
        GetEventParameter(event, kEventParamPreviousBounds, typeQDRectangle, 0, sizeof(Rect), 0, &prevr);
        GetEventParameter(event, kEventParamCurrentBounds, typeQDRectangle, 0, sizeof(Rect), 0, &curr);

        RECT parr;
        GetWindowRect((HWND)_this, &parr);
        parr.left += curr.left-prevr.left;
        parr.top += curr.top-prevr.top;
        parr.right += curr.right-prevr.right;
        parr.bottom += curr.bottom-prevr.bottom;        
        _this->m_whileresizing = true;
        SetWindowPos((HWND)_this, 0, parr.left, parr.right, parr.right-parr.left, parr.bottom-parr.top, SWP_NOZORDER|SWP_NOACTIVATE);
        _this->m_whileresizing = false;
      }
    }
    break;
    
    case kEventRawKeyDown:
    case kEventRawKeyUp:
    case kEventRawKeyModifiersChanged:
    {
      if (_this->m_wantallkeys) return eventNotHandledErr;
      
      WindowRef wndref = (WindowRef)[_this->m_cwnd windowRef];      
      if (wndref) 
      {
        ControlRef ctlref=0;
        GetKeyboardFocus(wndref, &ctlref);                
        if (ctlref)
        {
          ControlKind ctlkind = { 0, 0 };          
          GetControlKind(ctlref, &ctlkind);
          if (ctlkind.kind == kControlKindEditText || 
              ctlkind.kind == kControlKindEditUnicodeText ||
              ctlkind.kind == kControlKindHITextView) 
          {
            // ControlDefinitions.h, HITextViews.h, etc list control types,
            // we may want to pass on some other types too
            return eventNotHandledErr; 
          }
        } 
      }             
 
      UInt32 keycode;
      UInt32 modifiers;
      char c[2] = { 0, 0 };
      GetEventParameter(event, kEventParamKeyCode, typeUInt32, 0, sizeof(UInt32), 0, &keycode);
      GetEventParameter(event, kEventParamKeyModifiers, typeUInt32, 0, sizeof(UInt32), 0, &modifiers);
      GetEventParameter(event, kEventParamKeyMacCharCodes, typeChar, 0, sizeof(char), 0, &c[0]);
      
      NSEventType type;
      if (evtkind == kEventRawKeyDown) type = NSKeyDown;
      else if (evtkind == kEventRawKeyUp) type = NSKeyUp;
      else if (evtkind == kEventRawKeyModifiersChanged) type = NSFlagsChanged;      

      NSString* str = (NSString*)SWELL_CStringToCFString(c);
      NSTimeInterval ts = 0; // [[NSApp currentevent] timestamp];
      NSEvent* evt = [NSEvent keyEventWithType:type location:NSMakePoint(0,0)
                                modifierFlags:modifiers 
                                timestamp:ts windowNumber:0
                                context:[NSGraphicsContext currentContext]
                                characters:str charactersIgnoringModifiers:str 
                                isARepeat:NO keyCode:keycode];      
      [str release];
      if (evt) [NSApp sendEvent:evt];
      return noErr;         
    }   
  }
  return noErr;
}

void SWELL_CarbonWndHost_SetWantAllKeys(void* carbonhost, bool want)
{
  SWELL_hwndCarbonHost* h = (SWELL_hwndCarbonHost*)carbonhost;
  if (h) h->m_wantallkeys = want;
}

#endif // __LP

@implementation SWELL_hwndCarbonHost

- (id)initCarbonChild:(NSView *)parent rect:(Rect*)r composit:(bool)wantComp
{
  if (!(self = [super initChild:nil Parent:parent dlgProc:nil Param:nil])) return self;

  m_wantallkeys=false;
  
#ifndef __LP64__
  WindowRef wndref=0;
  CreateNewWindow (kPlainWindowClass, (wantComp ? kWindowCompositingAttribute : 0) |  kWindowStandardHandlerAttribute|kWindowNoShadowAttribute, r, &wndref);
  if (wndref)
  {
    // eventually we should set this and have the real NSWindow parent call ActivateWindow when activated/deactivated
    // SetWindowActivationScope( m_wndref, kWindowActivationScopeNone);    

    // adding a Carbon event handler to catch special stuff that NSWindow::initWithWindowRef
    // doesn't automatically redirect to a standard Cocoa window method
    
    ControlRef ctl=0;
    if (!wantComp) CreateRootControl(wndref, &ctl);  // creating root control here so callers must use GetRootControl

    EventTypeSpec winevts[] = 
    {
      { kEventClassWindow, kEventWindowActivated },
      { kEventClassWindow, kEventWindowGetClickActivation },
      { kEventClassWindow, kEventWindowHandleDeactivate },
      { kEventClassKeyboard, kEventRawKeyDown },
      { kEventClassKeyboard, kEventRawKeyUp },      
      { kEventClassKeyboard, kEventRawKeyModifiersChanged },        
    };
    int nwinevts = sizeof(winevts)/sizeof(EventTypeSpec);
          
    EventTypeSpec ctlevts[] = 
    {
      //{ kEventClassControl, kEventControlInitialize },
      //{ kEventClassControl, kEventControlDraw },            
      { kEventClassControl, kEventControlBoundsChanged },
    };
    int nctlevts = sizeof(ctlevts)/sizeof(EventTypeSpec);  
          
    EventHandlerRef wndhandler=0, ctlhandler=0;
    InstallWindowEventHandler(wndref, CarbonEvtHandler, nwinevts, winevts, self, &wndhandler);        
    if (!wantComp) InstallControlEventHandler(ctl, CarbonEvtHandler, nctlevts, ctlevts, self, &ctlhandler);
    m_wndhandler = wndhandler;
    m_ctlhandler = ctlhandler;
                    
    // initWithWindowRef does not retain // MAKE SURE THIS IS NOT BAD TO DO
    //CFRetain(wndref);

    m_cwnd = [[NSWindow alloc] initWithWindowRef:wndref];  
    [m_cwnd setDelegate:self];    
    
    ShowWindow(wndref);
    
    //[[parent window] addChildWindow:m_cwnd ordered:NSWindowAbove];
    //[self swellDoRepos]; 
    SetTimer((HWND)self,1,10,NULL);
  }  
#endif
  return self;
}

-(BOOL)swellIsCarbonHostingView { return YES; }


-(void)close
{
  KillTimer((HWND)self,1);
  
#ifndef __LP64__
  if (m_wndhandler)
  {
    EventHandlerRef wndhandler = (EventHandlerRef)m_wndhandler;
    RemoveEventHandler(wndhandler);
    m_wndhandler = 0;
  }
  if (m_ctlhandler)
  {
    EventHandlerRef ctlhandler = (EventHandlerRef)m_ctlhandler;
    RemoveEventHandler(ctlhandler);
    m_ctlhandler = 0;
  }
  
  if (m_cwnd) 
  {
    if ([m_cwnd parentWindow]) [[m_cwnd parentWindow] removeChildWindow:m_cwnd];
    [m_cwnd orderOut:self];
    [m_cwnd close];   // this disposes the owned wndref
    m_cwnd=0;
  }
#endif
}

-(void)dealloc
{
  [self close];
  [super dealloc];  // ?!
}

- (void)SWELL_Timer:(id)sender
{
#ifndef __LP64__
  id uinfo=[sender userInfo];
  if ([uinfo respondsToSelector:@selector(getValue)]) 
  {
    int idx=(int)(INT_PTR)[(SWELL_DataHold*)uinfo getValue];
    if (idx==1)
    {
      if (![self superview] || [[self superview] isHiddenOrHasHiddenAncestor])
      {
        NSWindow *oldw=[m_cwnd parentWindow];
        if (oldw)
        {
          [oldw removeChildWindow:(NSWindow *)m_cwnd];
          [m_cwnd orderOut:self];
        }
      }
      else
      {
        if (![m_cwnd parentWindow])
        {                
          NSWindow *par = [self window];
          if (par) 
          { 
            [par addChildWindow:m_cwnd ordered:NSWindowAbove];
            [self swellDoRepos];    
          }          
        }
        else 
        { 
          if (GetCurrentEventButtonState()&7)
          {
            if ([NSApp keyWindow] == [self window])
            {
              POINT p;
              GetCursorPos(&p);
              RECT r;
              GetWindowRect((HWND)self,&r);
              if (r.top>r.bottom)
              {
                int a=r.top;
                r.top=r.bottom;
                r.bottom=a;
              }
              if (m_cwnd && p.x >=r.left &&p.x < r.right && p.y >= r.top && p.y < r.bottom)
              {
                [(NSWindow *)m_cwnd makeKeyWindow];
              }
            }
          }
        }
      }
      return;
    }
    KillTimer((HWND)self,idx);
    return;
  }
#endif
}
- (LRESULT)onSwellMessage:(UINT)msg p1:(WPARAM)wParam p2:(LPARAM)lParam
{
  if (msg == WM_DESTROY)
  {
    if (m_cwnd) 
    {
      if ([NSApp keyWindow] == m_cwnd) // restore focus to highest window that is not us!
      {
        NSArray *ar = [NSApp orderedWindows];
        int x;
        for (x = 0; x < (ar ? [ar count] : 0); x ++)
        {
          NSWindow *w=[ar objectAtIndex:x];
          if (w && w != m_cwnd && [w isVisible]) { [w makeKeyWindow]; break; }
        }
      }
      
      [self close];
    }
  }
  return [super onSwellMessage:msg p1:wParam p2:lParam];
}
- (void)windowDidResignKey:(NSNotification *)aNotification
{
}
- (void)windowDidBecomeKey:(NSNotification *)aNotification
{
}


- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  if (m_cwnd)
  {
    // reparent m_cwnd to new owner
    NSWindow *neww=[self window];
    NSWindow *oldw=[m_cwnd parentWindow];
    if (neww != oldw)
    {
      if (oldw) [oldw removeChildWindow:m_cwnd];
    }
  }
}
-(void)swellDoRepos
{
#ifndef __LP64__
  if (m_cwnd)
  {
    RECT r;
    GetWindowRect((HWND)self,&r);
    if (r.top>r.bottom)
    {
      int a=r.top;
      r.top=r.bottom;
      r.bottom=a;
    }
    
    // [m_cwnd setFrameOrigin:NSMakePoint(r.left,r.top)];
    
    {
      Rect bounds;
      bounds.left = r.left;
      bounds.top = CGRectGetHeight(CGDisplayBounds(kCGDirectMainDisplay))-r.bottom;
      // GetWindowBounds (m_wndref, kWindowContentRgn, &bounds);
      bounds.right = bounds.left + (r.right-r.left);
      bounds.bottom = bounds.top + (r.bottom-r.top);
      
      WindowRef wndref = (WindowRef)[m_cwnd windowRef];
      SetWindowBounds (wndref, kWindowContentRgn, &bounds); 

      // might make sense to only do this on initial show, but doesnt seem to hurt to do it often
      WindowAttributes wa=0;
      GetWindowAttributes(wndref,&wa);
      
      if (wa&kWindowCompositingAttribute)
      {
//         [[m_cwnd contentView] setNeedsDisplay:YES];
         HIViewRef ref = HIViewGetRoot(wndref);
         if (ref)
         {
            // PrintAllHIViews(ref,"");
         
            HIViewRef ref2=HIViewGetFirstSubview(ref);
            while  (ref2)
            {                              
            /*
              HIRect r3=CGRectMake(0,0,bounds.right-bounds.left,bounds.bottom-bounds.top);
             HIViewRef ref3=HIViewGetFirstSubview(ref2);
             while (ref3)
             {
              HIViewSetVisible(ref3,true);            
              HIViewSetNeedsDisplay(ref3,true);
              HIViewSetFrame(ref3,&r3);
              ref3=HIViewGetNextView(ref3);
             }
             */

            //  HIViewSetVisible(ref2,true);            
              HIViewSetNeedsDisplay(ref2,true);
              ref2=HIViewGetNextView(ref2);
            }
            //HIViewSetVisible(ref,true);            
            HIViewSetNeedsDisplay(ref,true);
            HIViewRender(ref);
         }
      }
      else
      {
      
#if 0
        ControlRef rc=NULL;
        GetRootControl(m_wndref,&rc);
        if (rc)
        {
          RgnHandle rgn=NewRgn();
          GetControlRegion(rc,kControlEntireControl,rgn);
          UpdateControls(m_wndref,rgn);
          CloseRgn(rgn);
        }
#endif
        // Rect r={0,0,bounds.bottom-bounds.top,bounds.right-bounds.left};
        // InvalWindowRect(m_wndref,&r);
        
        // or we could just do: 
        DrawControls(wndref);
      }
    }
  }
#endif
}

- (void)viewDidMoveToSuperview
{
  [super viewDidMoveToSuperview];
  [self swellDoRepos];
}
- (void)setFrameSize:(NSSize)newSize
{
  [super setFrameSize:newSize];
  [self swellDoRepos];
}
- (void)setFrame:(NSRect)frameRect
{
  [super setFrame:frameRect];
  [self swellDoRepos];
}
- (void)setFrameOrigin:(NSPoint)newOrigin
{
  [super setFrameOrigin:newOrigin];
  [self swellDoRepos];
}


-(BOOL)isOpaque
{
  return NO;
}

@end

HWND SWELL_GetAudioUnitCocoaView(HWND parent, AudioUnit aunit, AudioUnitCocoaViewInfo* viewinfo, RECT* r)
{
  NSString* classname = (NSString*)(viewinfo->mCocoaAUViewClass[0]);
  if (!classname) return 0;
  
  NSBundle* bundle=0;
  if ([NSBundle respondsToSelector:@selector(bundleWithURL:)])
  {
    bundle=[NSBundle bundleWithURL:(NSURL*)viewinfo->mCocoaAUViewBundleLocation];    
  }

  if (!bundle)
  {
    NSString* path = (NSString*)(CFURLCopyFileSystemPath(viewinfo->mCocoaAUViewBundleLocation,kCFURLPOSIXPathStyle));
    if (path) 
    {
      bundle = [NSBundle bundleWithPath:path];
      [path release];
    }
  }

  if (!bundle) return 0;
	
  Class factoryclass = [bundle classNamed:classname];
  if (![factoryclass conformsToProtocol: @protocol(AUCocoaUIBase)]) return 0;
  if (![factoryclass instancesRespondToSelector: @selector(uiViewForAudioUnit:withSize:)]) return 0;
  id viewfactory = [[factoryclass alloc] init];
  if (!viewfactory) return 0;
  NSView* view = [viewfactory uiViewForAudioUnit:aunit withSize:NSMakeSize(r->right-r->left, r->bottom-r->top)];
  if (!view) 
  {
    [viewfactory release];
    return 0;
  }
  
  [(NSView*)parent addSubview:view];
  NSRect bounds = [view bounds];
  r->left = r->top = 0;
  r->right = bounds.size.width;
  r->bottom = bounds.size.height;
  [viewfactory release];

  return (HWND)view;
}


HWND SWELL_CreateCarbonWindowView(HWND viewpar, void **wref, RECT* r, bool wantcomp)  // window is created with a root control
{
  RECT wndr = *r;
  ClientToScreen(viewpar, (POINT*)&wndr);
  ClientToScreen(viewpar, (POINT*)&wndr+1);
  //Rect r2 = { wndr.top, wndr.left, wndr.bottom, wndr.right };
  Rect r2 = { wndr.bottom, wndr.left, wndr.top, wndr.right };
  SWELL_hwndCarbonHost *w = [[SWELL_hwndCarbonHost alloc] initCarbonChild:(NSView*)viewpar rect:&r2 composit:wantcomp];
  if (w) *wref = [w->m_cwnd windowRef];
  return (HWND)w;
}

void* SWELL_GetWindowFromCarbonWindowView(HWND cwv)
{
  SWELL_hwndCarbonHost* w = (SWELL_hwndCarbonHost*)cwv;
  if (w) return [w->m_cwnd windowRef];
  return 0;
}

void SWELL_AddCarbonPaneToView(HWND cwv, void* pane)  // not currently used
{
#ifndef __LP64__
  SWELL_hwndCarbonHost* w = (SWELL_hwndCarbonHost*)cwv;
  if (w)
  {
    WindowRef wndref = (WindowRef)[w->m_cwnd windowRef];
    if (wndref)
    {
      EventTypeSpec ctlevts[] = 
      {
        //{ kEventClassControl, kEventControlInitialize },
        //{ kEventClassControl, kEventControlDraw },            
        { kEventClassControl, kEventControlBoundsChanged },
      };
      int nctlevts = sizeof(ctlevts)/sizeof(EventTypeSpec);  
          
      EventHandlerRef ctlhandler = (EventHandlerRef)w->m_ctlhandler;   
      InstallControlEventHandler((ControlRef)pane, CarbonEvtHandler, nctlevts, ctlevts, w, &ctlhandler);
    }
  }
#endif
}


@interface NSButton (TextColor)

- (NSColor *)textColor;
- (void)setTextColor:(NSColor *)textColor;

@end

@implementation NSButton (TextColor)

- (NSColor *)textColor
{
  NSAttributedString *attrTitle = [self attributedTitle];
  int len = [attrTitle length];
  NSRange range = NSMakeRange(0, MIN(len, 1)); // take color from first char
  NSDictionary *attrs = [attrTitle fontAttributesInRange:range];
  NSColor *textColor = [NSColor controlTextColor];
  if (attrs) {
    textColor = [attrs objectForKey:NSForegroundColorAttributeName];
  }
  return textColor;
}

- (void)setTextColor:(NSColor *)textColor
{
  NSMutableAttributedString *attrTitle = [[NSMutableAttributedString alloc] 
                                          initWithAttributedString:[self attributedTitle]];
  int len = [attrTitle length];
  NSRange range = NSMakeRange(0, len);
  [attrTitle addAttribute:NSForegroundColorAttributeName 
                    value:textColor 
                    range:range];
  [attrTitle fixAttributesInRange:range];
  [self setAttributedTitle:attrTitle];
  [attrTitle release];
}

@end


static char* s_dragdropsrcfn = 0;
static void (*s_dragdropsrccallback)(const char*) = 0;

void SWELL_InitiateDragDrop(HWND hwnd, RECT* srcrect, const char* srcfn, void (*callback)(const char* dropfn))
{
  SWELL_FinishDragDrop();

  if (![(id)hwnd isKindOfClass:[SWELL_hwndChild class]]) return;

  s_dragdropsrcfn = strdup(srcfn);
  s_dragdropsrccallback = callback;
  
  char* p = s_dragdropsrcfn+strlen(s_dragdropsrcfn)-1;
  while (p >= s_dragdropsrcfn && *p != '.') --p;
  ++p;
  
  NSString* str = (NSString*)SWELL_CStringToCFString(p);  
  NSRect r = NSMakeRect(srcrect->left, srcrect->top, srcrect->right-srcrect->left, srcrect->bottom-srcrect->top);
  NSEvent* evt = [NSApp currentEvent];
  [(NSView*)hwnd dragPromisedFilesOfTypes:[NSArray arrayWithObject:str] fromRect:r source:(NSView*)hwnd slideBack:YES event:evt];
  [str release];
} 

// owner owns srclist, make copies here etc
void SWELL_InitiateDragDropOfFileList(HWND hwnd, RECT *srcrect, const char **srclist, int srccount, HICON icon)
{
  SWELL_FinishDragDrop();

  if (![(id)hwnd isKindOfClass:[SWELL_hwndChild class]]) return;
  
  NSMutableArray *ar = [[NSMutableArray alloc] initWithCapacity:srccount];
  int x;
  
  for(x=0;x<srccount;x++)
  {
    NSString *s = (NSString*)SWELL_CStringToCFString(srclist[x]);
    [ar addObject:s];
    [s release];
  }
  NSPasteboard *pb= [NSPasteboard pasteboardWithName:NSDragPboard];
  [pb declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType]  owner:(id)hwnd];
  [pb setPropertyList:ar forType:NSFilenamesPboardType];
  
  NSImage *img=NULL;// = [NSImage imageNamed:@"readoc"]; // todo!
  if (!img && icon) 
  {
    img = (NSImage *)GetNSImageFromHICON(icon);
    if (img)
    {
      img = [img copy];
      [img setFlipped:true];
      [img autorelease];
    }
  }
  
  if (!img)
  {
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    if (ws)
    {
      if (ar)
        img = [ws iconForFiles:ar];
    }
    // default image?
  }
  [(NSView *)hwnd dragImage:img at:NSMakePoint(srcrect->left,srcrect->top) offset:NSMakeSize(0,0) event:[NSApp currentEvent] pasteboard:pb source:(id)hwnd slideBack:YES];
  
  [ar release];
}


static bool _file_exists(const char* fn)
{
  struct stat sb= { 0 };
  return !stat(fn, &sb);
}

NSArray* SWELL_DoDragDrop(NSURL* droplocation)
{  
  NSArray* fnarr=0;
  if (s_dragdropsrcfn && s_dragdropsrccallback && droplocation)
  {  
    const char* srcpath=s_dragdropsrcfn;
    
    const char* fn = srcpath+strlen(srcpath)-1;
    while (fn >= srcpath && *fn != '/') --fn;
    ++fn;
    
    WDL_String destpath;
    destpath.SetFormatted(4096, "%s/%s", [[droplocation path] UTF8String], fn);
    
    bool ok=!_file_exists(destpath.Get());
    if (!ok)
    {
      int ret=NSRunAlertPanel(@"Copy",
            @"An item named \"%s\" already exists in this location. Do you want to replace it with the one you're moving?",
            @"Keep Both Files", @"Stop", @"Replace", fn);
      
      if (ret == -1) // replace
      {
        ok=true;
      }
      else if (ret == 1) // keep both
      {
        WDL_String base(destpath.Get());
        char* p=base.Get();
        int len=strlen(p);
        const char* ext="";
        int incr=0;   
        
        const char* q=fn+strlen(fn)-1;
        while (q > fn && *q != '.') --q;
        if (*q == '.') 
        {
          ext=q;
          len -= strlen(ext);
          p[len]=0;
        }
        
        int digits=0;
        int i;
        for (i=0; i < 3 && len > i+1 && isdigit(p[len-i-1]); ++i) ++digits;
        if (len > digits+1 && (p[len-digits-1] == ' ' || p[len-digits-1] == '-' || p[len-digits-1] == '_'))         
        {
          incr=atoi(p+len-digits);
          p[len-digits]=0;
        }
        else 
        {
          base.Append(" ");
        }
 
        WDL_String trypath;
        while (!ok && ++incr < 1000)
        {
          trypath.SetFormatted(4096, "%s%03d%s", base.Get(), incr, ext);
          ok=!_file_exists(trypath.Get());
        }

        if (ok) destpath.Set(trypath.Get());
      }
    }
    
    if (ok)
    {
      s_dragdropsrccallback(destpath.Get());
      ok=_file_exists(destpath.Get());
    }
  
    if (ok)
    {
      fn=destpath.Get();
      fn += strlen(fn)-1;
      while (fn >= destpath.Get() && *fn != '/') --fn;
      ++fn;
            
      NSString* nfn=(NSString*)SWELL_CStringToCFString(fn);
      fnarr=[NSArray arrayWithObject:nfn];
      [nfn release];
    }
  }
  
  SWELL_FinishDragDrop();  
  return fnarr;
}  

void SWELL_FinishDragDrop()
{
  free(s_dragdropsrcfn);
  s_dragdropsrcfn = 0;
  s_dragdropsrccallback = 0;  
}

bool SWELL_SetGLContextToView(HWND h)
{
  if (!h) [NSOpenGLContext clearCurrentContext];
  else if ([(id)h isKindOfClass:[SWELL_hwndChild class]])
  {
    SWELL_hwndChild *hc = (SWELL_hwndChild*)h;
    if (hc->m_glctx)
    {
      [hc->m_glctx makeCurrentContext];
      return true;
    }
  }
  return false;
}

void SWELL_SetViewGL(HWND h, bool wantGL)
{
  if (h && [(id)h isKindOfClass:[SWELL_hwndChild class]])
  {
    SWELL_hwndChild *hc = (SWELL_hwndChild*)h;
    if (wantGL != !!hc->m_glctx)
    {
      if (wantGL) 
      {
        NSOpenGLPixelFormatAttribute atr[] = { 
            96/*NSOpenGLPFAAllowOfflineRenderers*/, // allows use of NSSupportsAutomaticGraphicsSwitching and no gpu-forcing
            (NSOpenGLPixelFormatAttribute)0
        }; // todo: optionally add any attributes before the 0
        if (!Is105Plus()) atr[0]=0; // 10.4 can't use offline renderers and will fail trying

        NSOpenGLPixelFormat *fmt  = [[NSOpenGLPixelFormat alloc] initWithAttributes:atr];
        
        hc->m_glctx = [[NSOpenGLContext alloc] initWithFormat:fmt shareContext:nil];
        [fmt release];
      }
      else
      {
        if ([NSOpenGLContext currentContext] == hc->m_glctx) [NSOpenGLContext clearCurrentContext];
        [hc->m_glctx release];
        hc->m_glctx=0;
      }
    }
    
  }
}

bool SWELL_GetViewGL(HWND h)
{
  return h && [(id)h isKindOfClass:[SWELL_hwndChild class]] && ((SWELL_hwndChild*)h)->m_glctx;
}
void DrawSwellViewRectImpl(SWELL_hwndChild *view, NSRect rect, HDC hdc)
{
  if (view->m_hashaddestroy) 
  {
    return;
  }    
  view->m_paintctx_hdc=hdc;
  if (view->m_paintctx_hdc && view->m_glctx)
  {
    view->m_paintctx_hdc->GLgfxctx = view->m_glctx;
    
    [view->m_glctx setView:view];
    [view->m_glctx makeCurrentContext];
    [view->m_glctx update];
  }
  view->m_paintctx_rect=rect;
  view->m_paintctx_used=false;
  DoPaintStuff(view->m_wndproc,(HWND)view,view->m_paintctx_hdc,&view->m_paintctx_rect);
  
  if (view->m_paintctx_hdc && view->m_glctx && [NSOpenGLContext currentContext] == view->m_glctx)
  {
    [NSOpenGLContext clearCurrentContext]; 
  }
  view->m_paintctx_hdc=0;
  if (!view->m_paintctx_used) {
    /*[super drawRect:rect];*/
  }
  
#if 0
  // debug: show everything
  static CGColorSpaceRef cspace;
  if (!cspace) cspace=CGColorSpaceCreateDeviceRGB();
  float cols[4]={0.0f,1.0f,0.0f,0.8f};
  CGColorRef color=CGColorCreate(cspace,cols);
  
  CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
  CGContextSetStrokeColorWithColor(ctx,color);
  CGContextStrokeRectWithWidth(ctx, CGRectMake(rect.origin.x,rect.origin.y,rect.size.width,rect.size.height), 1);
  
  CGColorRelease(color);
  
  cols[0]=1.0f;
  cols[1]=0.0f;
  cols[2]=0.0f;
  cols[3]=1.0f;
  color=CGColorCreate(cspace,cols);
  
  NSRect rect2=[view bounds];
  CGContextSetStrokeColorWithColor(ctx,color);
  CGContextStrokeRectWithWidth(ctx, CGRectMake(rect2.origin.x,rect2.origin.y,rect2.size.width,rect2.size.height), 1);
  
  
  CGColorRelease(color);
  
  cols[0]=0.0f;
  cols[1]=0.0f;
  cols[2]=1.0f;
  cols[3]=0.7f;
  color=CGColorCreate(cspace,cols);
  cols[3]=0.25;
  cols[2]=0.5;
  CGColorRef color2=CGColorCreate(cspace,cols);
  
  NSArray *ar = [view subviews];
  if (ar)
  {
    int x;
    for(x=0;x<[ar count];x++)  
    {
      NSView *v = [ar objectAtIndex:x];
      if (v && ![v isHidden])
      {
        NSRect rect = [v frame];
        CGContextSetStrokeColorWithColor(ctx,color);
        CGContextStrokeRectWithWidth(ctx, CGRectMake(rect.origin.x,rect.origin.y,rect.size.width,rect.size.height), 1);
        CGContextSetFillColorWithColor(ctx,color2);
        CGContextFillRect(ctx, CGRectMake(rect.origin.x,rect.origin.y,rect.size.width,rect.size.height));
      }
    }
    
    // draw children
  }
  CGColorRelease(color);
  CGColorRelease(color2);
  
#endif
  
  
  
}

void swellRenderOptimizely(int passflags, SWELL_hwndChild *view, HDC hdc, BOOL doforce, WDL_PtrList<void> *needdraws, const NSRect *rlist, int rlistcnt, int draw_xlate_x, int draw_xlate_y, bool iscv)
{
  if (view->m_isdirty&1) doforce=true;
  NSArray *sv = [view subviews];
  if (doforce&&(passflags & ([sv count]?1:2)))
    DrawSwellViewRectImpl(view,[view bounds], hdc);
  
  if (sv)
  {
    [sv retain];
    int x,n=[sv count];
    HBRUSH bgbr=0;
    bool bgbr_valid=false;
    for(x=0;x<n;x++)
    {
      NSView *v = (NSView *)[sv objectAtIndex:x];
      if (v && ![v isHidden])
      {          
        bool isSwellChild = !![v isKindOfClass:[SWELL_hwndChild class]];
        
        if (doforce||(isSwellChild && ((SWELL_hwndChild*)v)->m_isdirty)|| [v needsDisplay])
        {
          if (isSwellChild)
          {
            NSRect fr = [v frame];
            CGContextSaveGState(hdc->ctx);
            CGContextClipToRect(hdc->ctx,CGRectMake(fr.origin.x,fr.origin.y,fr.size.width,fr.size.height));
            CGContextTranslateCTM(hdc->ctx, fr.origin.x,fr.origin.y);            
            swellRenderOptimizely(passflags,(SWELL_hwndChild*)v,hdc,doforce,needdraws,rlist,rlistcnt,draw_xlate_x-(int)fr.origin.x,draw_xlate_y-(int)fr.origin.y,false);
            CGContextRestoreGState(hdc->ctx);
            if (passflags&2) [v setNeedsDisplay:NO];
            bgbr_valid=false; // code in swellRenderOptimizely() may trigger WM_CTLCOLORDLG which may invalidate our brush, so clear the cached value here
          }
          else if (passflags&1)
          {
            if ([v isKindOfClass:[NSScrollView class]])
            {
              NSView *sv = [(NSScrollView *)v contentView];
              if (sv)
              {
                [v retain];
                needdraws->Add((void*)(INT_PTR)(doforce?1:0));
                needdraws->Add(v);
                v=sv;
              }
            }
            [v retain];
            if (!doforce && ![v isOpaque]) 
            {
              
              NSRect fr=  [v frame];
              
              // we could recursively go up looking for WM_CTLCOLORDLG, but actually we just need to use the current window            
              if (!bgbr_valid) // note that any code in this loop that does anything that could trigger messages might invalidate bgbr, so it should clear bgbr_checked here
              {
                bgbr=(HGDIOBJ)SendMessage((HWND)view,WM_CTLCOLORDLG,(WPARAM)hdc,(LPARAM)view);
                bgbr_valid=true;
              }
                   
              if (!iscv) fr = [view convertRect:fr toView:[[view window] contentView]];
                    
              int ri;
              for(ri=0;ri<rlistcnt;ri++)
              {
                NSRect r=rlist[ri];
                r.origin.x--;
                r.origin.y--;
                r.size.width+=2;
                r.size.height+=2;
                
                NSRect ff = NSIntersectionRect(fr,r);
                if (ff.size.width>0 && ff.size.height>0)
                {
                  RECT r={(int)ff.origin.x,(int)ff.origin.y,(int)(ff.origin.x+ff.size.width),(int)(ff.origin.y+ff.size.height)};                    
                  r.left+=draw_xlate_x;
                  r.right+=draw_xlate_x;
                  r.top+=draw_xlate_y;
                  r.bottom+=draw_xlate_y;
                  if (bgbr_valid && bgbr &&  bgbr != (HBRUSH)1) FillRect(hdc,&r,bgbr);
                  else SWELL_FillDialogBackground(hdc,&r,3);
                }
              }
            }
            needdraws->Add((void*)(INT_PTR)(doforce?1:0));
            needdraws->Add(v);     
          }
        }
      }
    }
    [sv release];
  }
  if (passflags&2)
     view->m_isdirty=0;
}

#endif

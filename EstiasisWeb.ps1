<#
  EstiasisWeb.ps1 - mobile web frontend for the Estiasis restaurant POS.
  Serves a phone-friendly PWA on the LAN and proxies the Estiasis WebApi (tables, ordering,
  split bills, drafts, AI order parsing, printing, close). Open on a phone at:
  http://<this-machine-LAN-ip>:8095

  Credentials are NOT hardcoded. Provide them as parameters, or (preferred) drop an untracked
  estiasis_config.json next to this script (see estiasis_config.example.json).
#>
param(
  [int]$Port = 8095,
  [string]$Eb = 'http://127.0.0.1/wa_estiasis',                 # Estiasis WebApi base URL (IIS app)
  [string]$Basic = 'Basic REPLACE_WITH_BASE64_CLIENTID_AND_SECRET',  # IdentityServer client auth header
  [string]$User = 'REPLACE_WITH_POS_USERNAME',                  # POS login (resource-owner-password grant)
  [string]$Pass = 'REPLACE_WITH_POS_PASSWORD',
  [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$script:dev = [guid]::NewGuid().ToString()
$script:token = $null

# Greek UI labels from a UTF-8 file (keeps this script ASCII)
$base = if($PSCommandPath){ Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }

# Optional local config (gitignored) so credentials never live in the tracked script.
$cfgFile = Join-Path $base 'estiasis_config.json'
if(Test-Path $cfgFile){ try{ $cfg=[System.IO.File]::ReadAllText($cfgFile,[Text.Encoding]::UTF8)|ConvertFrom-Json; if($cfg.Eb){ $Eb=[string]$cfg.Eb }; if($cfg.Basic){ $Basic=[string]$cfg.Basic }; if($cfg.User){ $User=[string]$cfg.User }; if($cfg.Pass){ $Pass=[string]$cfg.Pass } }catch{} }

$labelsFile = Join-Path $base 'estiasisweb_labels.json'
$script:labels = '{"tables":"tables","open":"open","empty":"(empty)","qty":"Quantity","price":"Price","comment":"comment (optional)","add":"Add","cancel":"Cancel","print":"Print","close":"Close table","closeConfirm":"Close the table?","saving":"Saving...","printed":"Printed","error":"Error","back":"Back","ok":"OK","cancelDraft":"Cancel draft","cancelDraftConfirm":"Discard draft?","selectItem":"Select an item","cantRemove":"Nothing to remove","search":"Search product...","move":"Move table","moveTo":"Move to an empty table","closeFailed":"Table did not close","noteCat":"Personal note","notePlaceholder":"Write the order freely...","aiThinking":"AI thinking...","aiAdded":"Added","aiNone":"Nothing to add","aiNoKey":"AI not configured","aiErr":"AI error","rulesTitle":"AI rules","rulesHint":"One rule per line","rulesSaved":"Saved","editConflict":"Item changed elsewhere","noteDelConfirm":"Delete note?","seqHeader":"Course","addLevel":"+ Course","seqDelConfirm":"Delete course?","seqDelete":"Delete course","parallelConfirm":"Table changed on another device meanwhile. OK anyway?","verifyFail":"Could not verify the table. OK anyway?","printCurrent":"Print current bill","printAll":"Print all bills","addBill":"+ Split bill","billHeader":"Bill","billMain":"Main","billMove":"Move to which bill?","billDelete":"Delete bill","billDelConfirm":"What about the dishes?","billDelDishes":"Delete the dishes too","billXfer":"Move to"}'
if(Test-Path $labelsFile){ try{ $t=[System.IO.File]::ReadAllText($labelsFile,[System.Text.Encoding]::UTF8); if($t -and $t.Trim().StartsWith('{')){ $script:labels=$t } }catch{} }

function Login {
  $body = "grant_type=password&username=$User&password=$Pass&deviceId=$($script:dev)"
  $r = Invoke-RestMethod "$Eb/connect/token" -Method Post -Headers @{Authorization=$Basic} -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 12
  $script:token = $r.access_token
}
function ApiRaw([string]$path){
  if(-not $script:token){ Login }
  $u = "$Eb/$path"
  try { return (Invoke-WebRequest $u -Headers @{Authorization="Bearer $($script:token)"} -UseBasicParsing -TimeoutSec 15).Content }
  catch { if($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401){ Login; return (Invoke-WebRequest $u -Headers @{Authorization="Bearer $($script:token)"} -UseBasicParsing -TimeoutSec 15).Content }; throw }
}
function ApiPost([string]$path,[string]$body,[string]$ctype='application/json'){
  if(-not $script:token){ Login }
  $u = "$Eb/$path"
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$body)
  try { return (Invoke-WebRequest $u -Method Post -Headers @{Authorization="Bearer $($script:token)"} -Body $bytes -ContentType $ctype -UseBasicParsing -TimeoutSec 20).Content }
  catch { if($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401){ Login; return (Invoke-WebRequest $u -Method Post -Headers @{Authorization="Bearer $($script:token)"} -Body $bytes -ContentType $ctype -UseBasicParsing -TimeoutSec 20).Content }; throw }
}

# --- AI auto-fill via the Anthropic API. Key read from estiasis_ai_key.txt (next to this script) or the
#     ANTHROPIC_API_KEY env var. The key stays server-side and is never sent to the phone. ---
$script:aiMenu = $null
$script:aiMenuAt = [datetime]::MinValue
function AiKey {
  $kf = Join-Path $base 'estiasis_ai_key.txt'
  if(Test-Path $kf){ try{ $k=([System.IO.File]::ReadAllText($kf)).Trim(); if($k){ return $k } }catch{} }
  if($env:ANTHROPIC_API_KEY -and $env:ANTHROPIC_API_KEY.Trim()){ return $env:ANTHROPIC_API_KEY.Trim() }
  return $null
}
function Get-AiMenu {
  if($script:aiMenu -and ((Get-Date)-$script:aiMenuAt).TotalMinutes -lt 360){ return $script:aiMenu }
  $pl = ApiRaw 'api/PricelistsFull' | ConvertFrom-Json
  $active = $pl.priceLists | Where-Object { $_.priceList_ID -eq $pl.defaultPriceList } | Select-Object -First 1
  if(-not $active){ $active = $pl.priceLists | Select-Object -First 1 }
  $items = $active.priceListItems
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  $sb = New-Object System.Text.StringBuilder
  $seen = @{}
  $cats = $items | Where-Object { $_.type -eq 0 } | Sort-Object sort
  foreach($c in $cats){
    $prods = $items | Where-Object { $_.type -eq 2 -and $_.parent_ID -eq $c.priceListItem_ID } | Sort-Object sort
    if(-not $prods){ continue }
    [void]$sb.AppendLine('== ' + [string]$c.description + ' ==')
    foreach($p in $prods){ [void]$sb.AppendLine([string]$p.priceListItem_ID + ' | ' + [string]$p.description + ' | ' + ([double]$p.price).ToString('0.00',$inv)); $seen[[int]$p.priceListItem_ID]=$true }
  }
  $orphans = $items | Where-Object { $_.type -eq 2 -and -not $seen.ContainsKey([int]$_.priceListItem_ID) } | Sort-Object sort
  if($orphans){ [void]$sb.AppendLine('== OTHER =='); foreach($p in $orphans){ [void]$sb.AppendLine([string]$p.priceListItem_ID + ' | ' + [string]$p.description + ' | ' + ([double]$p.price).ToString('0.00',$inv)) } }
  $script:aiMenu = $sb.ToString(); $script:aiMenuAt = Get-Date
  return $script:aiMenu
}
function Get-AiRules {
  $rf = Join-Path $base 'estiasis_ai_rules.txt'
  if(Test-Path $rf){ try{ $t=([System.IO.File]::ReadAllText($rf,[Text.Encoding]::UTF8)).Trim(); if($t){ return $t } }catch{} }
  return ''
}
function Build-AiRequest([string]$note, [int]$level=1, $lnames=$null){
  $key = AiKey
  if(-not $key){ return @{ ok=$false; out='{"error":"nokey"}' } }
  if($level -lt 1){ $level=1 }
  $menu = Get-AiMenu
  $rules = Get-AiRules
  $instr = "You convert a restaurant waiter's free-text order note into structured line items chosen ONLY from the fixed menu. The note is informal Greek with possible typos, missing accents and abbreviations.`n" +
    "Rules:`n" +
    "- Map each thing written to the single best-matching menu product. Match tolerantly: ignore accents and case, allow typos and shorthand, use the category headers as context.`n" +
    "- HOUSE NOTES (if present below) define standard item compositions and shorthand (e.g. what 'with everything' includes). Use them to interpret the order: map a 'without X' or 'extra X' request to the matching product with that change written in comment.`n" +
    "- Use ONLY product_id values present in the menu. Never invent an id. If something has no reasonable match, skip it.`n" +
    "- quantity: the count implied (default 1).`n" +
    "- comment: if a modification or instruction is given for an item (e.g. without onion, well done, takeaway), put that short Greek text in comment; otherwise null.`n" +
    "- price: set a positive number when the waiter states a different price, or when a HOUSE NOTE defines a price adjustment (e.g. a half portion = half the menu price for that dish); otherwise null.`n" +
    "- seq: an integer >= 1, the serving-order group for the item. This note belongs to group $level. By DEFAULT set seq = $level for EVERY item (they are served together).`n" +
    "- Use a different seq ONLY when the note itself states an order of the dishes:`n" +
    "   * progression cues (Greek words like 'gia arxh' / 'ksekina' / 'prwta' = to start / first, then 'sth synexeia' / 'meta' = then / afterwards): the first batch stays in group $level, and each following batch goes one group higher than the previous (increase the group number by 1 each time, no gaps).`n" +
    "   * course tags (Greek 'orektiko' = appetizer/starter, 'kyrios' = main course): the appetizer stays in group $level and the main course goes one group higher.`n" +
    "   * if the note gives explicit group numbers per dish, honor them.`n" +
    "   * if NAMED SERVING GROUPS are listed below, put each dish in the group whose name best matches its type.`n" +
    "- If the ordering is unclear or not stated, set seq = $level for that item; do NOT invent an order the note does not state.`n" +
    "- groups: also return a list of {seq, name}. For any serving group whose purpose is clear from the note, give a SHORT name written in GREEK (for example the Greek word for appetizers/starters for a starters group, or the Greek word for main courses for a mains group; or a course/round name). This INCLUDES the current group $level itself: if the items in group $level clearly form one category, name group $level too (it currently has no name). Name a group ONLY when you are confident; otherwise leave it out. Return an empty list if nothing needs a name. Do not name a group just because it exists.`n" +
    "- Output every item the note describes (the note is the full order). Output strictly via the provided schema."
  $schema = @{
    type='object'; additionalProperties=$false; required=@('items','groups');
    properties=@{ items=@{ type='array'; items=@{
      type='object'; additionalProperties=$false; required=@('product_id','quantity','seq','comment','price');
      properties=@{ product_id=@{ type='integer' }; quantity=@{ type='integer' }; seq=@{ type='integer' }; comment=@{ anyOf=@( @{type='string'}, @{type='null'} ) }; price=@{ anyOf=@( @{type='number'}, @{type='null'} ) } }
    } };
    groups=@{ type='array'; items=@{ type='object'; additionalProperties=$false; required=@('seq','name'); properties=@{ seq=@{ type='integer' }; name=@{ type='string' } } } } }
  }
  $userText = "NOTE:`n" + $note
  $sys = @( @{ type='text'; text=$instr } )
  if($rules){ $sys += @{ type='text'; text=("HOUSE NOTES (general rules that always apply when interpreting the order):`n"+$rules) } }
  $gn=''
  if($lnames){ try{ foreach($pn in $lnames.PSObject.Properties){ $vv=[string]$pn.Value; if($vv -and $vv.Trim()){ $gn += ("- group "+$pn.Name+" = "+$vv.Trim()+"`n") } } }catch{} }
  if($gn){ $sys += @{ type='text'; text=("NAMED SERVING GROUPS (group number = its purpose; place dishes accordingly):`n"+$gn) } }
  $sys += @{ type='text'; text=("MENU:`n"+$menu); cache_control=@{ type='ephemeral' } }
  $body = @{
    model='claude-opus-4-8'; max_tokens=2048;
    system=$sys;
    messages=@( @{ role='user'; content=$userText } );
    output_config=@{ format=@{ type='json_schema'; schema=$schema } }
  }
  $json = ConvertTo-Json -InputObject $body -Depth 30 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $hdr = @{ 'x-api-key'=$key; 'anthropic-version'='2023-06-01' }
  return @{ ok=$true; bytes=$bytes; hdr=$hdr }
}

$HTML = @'
<!doctype html><html><head><meta charset="utf-8"><title>AlexEstiasis</title>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,interactive-widget=resizes-content">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="AlexEstiasis">
<meta name="mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#222831">
<link rel="manifest" href="/manifest.json">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="icon" type="image/png" href="/icon-192.png">
<style>
 *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
 html,body{height:100%}
 body{margin:0;font-family:-apple-system,Segoe UI,Arial,sans-serif;background:#111;color:#fff;overflow:hidden}
 #app{display:flex;flex-direction:column;height:100vh;height:100dvh}
 header{display:flex;align-items:center;gap:4px;padding:10px 10px;background:#2b2f36;flex:0 0 auto;position:relative;z-index:10}
 header .t{font-size:17px;font-weight:600;flex:1;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 header .b{background:none;border:0;color:#fff;font-size:20px;padding:6px 10px;cursor:pointer;min-width:42px}
 header .b.txt{font-size:15px;font-weight:600;min-width:auto;padding:6px 9px}
 header #hback{color:#cdd3dc}
 header #hcog{color:#cdd3dc;font-size:22px}
 header #hok{color:#6fe39a;font-weight:700}
 #status{font-size:12px;color:#9aa4b2;padding:4px 12px;flex:0 0 auto}
 #grid{display:grid;grid-template-columns:repeat(3,1fr);grid-auto-rows:min-content;align-content:start;gap:6px;padding:8px 8px 20px;overflow:auto;flex:1}
 .tile{aspect-ratio:1.7/1;border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:600;color:#fff;cursor:pointer;border:1px solid rgba(0,0,0,.35);text-shadow:0 1px 2px rgba(0,0,0,.5);overflow:hidden;min-width:0}
 .tile:active{filter:brightness(1.25)}
 #tv{display:none;flex-direction:column;flex:1;min-height:0}
 #platewrap{display:flex;flex:0 0 auto;height:36vh}
 #sheetgrip{flex:0 0 auto;height:22px;background:#1d1f24;display:flex;align-items:center;justify-content:center;touch-action:none;cursor:row-resize;border-top:2px solid #000;border-bottom:1px solid #000}
 #sheetgrip::before{content:"";width:46px;height:5px;border-radius:3px;background:#5a6270}
 #plates{flex:1;overflow:auto;background:#161616}
 #qbar{flex:0 0 58px;display:none;flex-direction:column;justify-content:center;gap:10px;background:#1b1d22;border-left:1px solid #000;padding:8px 0}
 #qbar button{height:58px;margin:0 6px;border:0;border-radius:8px;background:#2b2f36;color:#fff;font-size:30px;font-weight:700;cursor:pointer}
 #qbar button:active{filter:brightness(1.35)}
 #qbar #qminus{color:#ff9a9a}
 #qbar #qedit{color:#9ac8ff;font-size:24px}
 #qbar #qdel{color:#ff9a9a;font-size:22px;display:none}
 #qbar #qai{font-size:24px;display:none}
 #qbar #qai.busy{opacity:.45}
 #qbar #qup,#qbar #qdown{display:none;font-size:20px;color:#bfe3a0}
 .lvlhdr{display:flex;justify-content:space-between;align-items:center;padding:6px 12px;background:#1f2530;color:#9ac8ff;font-size:12px;font-weight:700;letter-spacing:.5px;border-top:2px solid #333;border-bottom:1px solid #333;cursor:pointer}
 .lvlhdr.act{background:#22406a;color:#fff;border-left:4px solid #5a86d6}
 .lvlhdr.selh{box-shadow:inset 3px 0 0 #5a86d6,inset -3px 0 0 #5a86d6}
 #lnb_del{margin-top:12px;width:100%;padding:12px;border:0;border-radius:10px;background:#7a2a2a;color:#fff;font-size:15px;font-weight:600;cursor:pointer}
 .lvlhdr .lvln{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .lvlhdr .lvledit{color:#9ac8ff;font-size:15px;padding:2px 4px 2px 10px;flex:0 0 auto}
 .lvlhdr .lvldel{color:#ff9a9a;font-size:14px;padding:2px 4px 2px 8px;flex:0 0 auto}
 .lvlsec{margin-bottom:10px;border:1px solid #262b33;border-radius:8px;overflow:hidden}
 .lvlempty{padding:9px 12px;color:#5a6270;font-size:11px;font-style:italic;background:#13161a}
 .addlvl{padding:11px 12px;text-align:center;color:#7fb0ff;font-size:14px;font-weight:600;border-top:1px dashed #3a3f48;background:#171a1f;cursor:pointer}
 .addlvlico{width:17px;height:17px;vertical-align:-4px;margin-left:7px}
 .addbill{color:#e0b34a}
 .billbar{display:flex;align-items:center;gap:8px;padding:7px 10px;margin:0 0 9px;background:#1d1a12;border:1px solid #5a4a1e;border-radius:8px}
 .billnav{flex:0 0 auto;width:36px;height:30px;line-height:30px;text-align:center;color:#e0b34a;font-size:18px;background:#13110b;border-radius:6px;cursor:pointer;user-select:none}
 .billnav:active{filter:brightness(1.6)}
 .billlbl{flex:1;text-align:center;color:#e0b34a;font-weight:700;font-size:14px}
 .billtot{flex:0 0 auto;color:#fff;font-weight:700;font-size:14px;min-width:54px;text-align:right}
 #qbill{color:#e0b34a}
 #bplist{display:flex;flex-direction:column;gap:8px}
 .billpick{padding:13px 12px;font-size:16px;text-align:left;background:#13110b;color:#e0b34a;border:1px solid #5a4a1e;border-radius:8px;cursor:pointer}
 .billpick.cur{background:#2a2412;color:#fff;border-color:#e0b34a}
 .billpick:active{filter:brightness(1.4)}
 .addlvl:active{filter:brightness(1.4)}
 .pl{display:flex;gap:8px;padding:9px 12px;border-bottom:1px solid #222;font-size:15px;align-items:flex-start}
 .pl .q{color:#9aa4b2;min-width:34px;font-variant-numeric:tabular-nums}
 .pl .n{flex:1}
 .pl .v{font-variant-numeric:tabular-nums;color:#dfe3ea}
 .pl.ext{padding-left:26px;font-size:13px;color:#9aa4b2}
 .pl .cmt{font-size:12px;color:#e0b46a;font-style:italic;margin-top:2px}
 .pl.pend{border-left:3px solid #46c46a;background:#15241a}
 .pl.pend.neg{border-left:3px solid #e06a6a;background:#241616}
 .pl.neg .q,.pl.neg .n,.pl.neg .v{color:#ff9a9a}
 .pl.sel{background:#243049;box-shadow:inset 3px 0 0 #5a86d6,inset -3px 0 0 #5a86d6}
 .pl.note{border-left:3px solid #e0b46a;background:#211c12;padding:8px 12px;margin:5px 6px;border-radius:8px;border-bottom:0;box-shadow:0 1px 2px rgba(0,0,0,.4)}
 .pl.note .ntext{flex:1;max-height:120px;overflow:auto;white-space:pre-wrap;word-break:break-word;font-size:14px;line-height:1.45;color:#f0e2c8}
 .pl.note.ndraft{border-left:3px solid #46c46a;background:#15241a}
 .pl.note.sel{box-shadow:0 0 0 2px #6a9bff,0 1px 4px rgba(0,0,0,.5)}
 .pl.note.ndraft .ntext{color:#d6f0d8}
 #pempty{padding:22px;text-align:center;color:#666}
 #srch{flex:0 0 auto;padding:6px;background:#1d1f24;border-bottom:1px solid #000}
 #psearch{width:100%;background:#0f1115;border:1px solid #3a3f48;color:#fff;border-radius:8px;padding:10px 12px;font-size:16px}
 #menu{flex:1;overflow:auto;background:#1d1f24;touch-action:pan-y}
 .mgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;padding:4px}
 .cat,.prod{min-height:62px;display:flex;align-items:center;justify-content:center;text-align:center;padding:6px;font-size:14px;font-weight:600;color:#102040;cursor:pointer;border-radius:3px;line-height:1.15}
 .cat{background:#aebfd9}.prod{background:#eef0f5}.prod.back{background:#d6d0ec;font-size:24px;color:#555}
 .cat.notecat{background:#e0b46a;color:#3a2410}
 .cat:active,.prod:active{filter:brightness(.9)}
 #amenu{display:none;position:absolute;top:48px;right:8px;background:#2b2f36;border:1px solid #3a3f48;border-radius:8px;overflow:hidden;z-index:20;box-shadow:0 6px 20px rgba(0,0,0,.5)}
 #amenu button{display:block;width:200px;text-align:left;background:none;border:0;color:#fff;padding:13px 16px;font-size:15px;cursor:pointer}
 #amenu button:active{background:#3a3f48}
 #amenu #m_canceldraft{color:#e0b46a;border-top:1px solid #3a3f48}
 #amenu #m_close{color:#ff9a9a;border-top:1px solid #3a3f48}
 #amenu #m_addlvl{color:#7fb0ff;border-top:1px solid #3a3f48}
 #amenu #m_addbill{color:#e0b34a}
 #sheet,#esheet,#nsheet,#lnsheet,#billsheet,#billedit{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:30;align-items:flex-end}
 .billedit{margin-left:10px;color:#e0b34a;font-size:15px;cursor:pointer}
 .billdel{margin-left:10px;color:#ff9a9a;font-size:14px;cursor:pointer}
 #nsh_text{width:100%;min-height:150px;max-height:42vh;background:#0f1115;border:1px solid #3a3f48;color:#fff;border-radius:8px;padding:10px;font-size:16px;line-height:1.45;resize:none;box-sizing:border-box}
 .sbox{background:#22262d;width:100%;border-radius:14px 14px 0 0;padding:16px;display:flex;flex-direction:column;gap:14px}
 .sh{font-size:18px;font-weight:700;text-align:center}
 .srow{display:flex;align-items:center;gap:10px;font-size:15px}
 .srow .sl{flex:1;color:#9aa4b2}
 .qc{display:flex;align-items:center;gap:14px}
 .qc button{width:42px;height:42px;border-radius:8px;border:0;background:#3a3f48;color:#fff;font-size:22px;cursor:pointer}
 #sh_qty{font-size:20px;font-weight:700;min-width:30px;text-align:center}
 #sh_price{width:90px;background:#0f1115;border:1px solid #3a3f48;color:#fff;border-radius:8px;padding:9px;font-size:16px}
 .cmt{flex:1;background:#0f1115;border:1px solid #3a3f48;color:#fff;border-radius:8px;padding:10px;font-size:15px}
 .oneline{resize:none;overflow:hidden;white-space:nowrap;font-family:inherit;line-height:1.25}
 .btns{gap:10px}
 .btns button{flex:1;padding:13px;border:0;border-radius:10px;font-size:16px;font-weight:600;cursor:pointer}
 .btns .cancel{background:#3a3f48;color:#fff}.btns .addb{background:#2a7e4f;color:#fff}
 #toast{display:none;position:fixed;bottom:24px;left:50%;transform:translateX(-50%);background:#000;color:#fff;padding:10px 18px;border-radius:20px;font-size:14px;z-index:40;border:1px solid #3a3f48}
 #moveov{display:none;position:fixed;top:0;left:0;right:0;bottom:0;width:100%;max-width:100%;background:#111;z-index:36;flex-direction:column;overflow:hidden}
 .movebar{display:flex;align-items:center;gap:8px;padding:12px 12px;background:#2b2f36;flex:0 0 auto}
 .movebar span{flex:1;min-width:0;font-size:17px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .movebar .mvx{background:none;border:0;color:#fff;font-size:18px;padding:6px 12px;cursor:pointer}
 #movegrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));grid-auto-rows:min-content;align-content:start;gap:6px;padding:8px 8px 20px;overflow-x:hidden;overflow-y:auto;flex:1;min-width:0;min-height:0;width:100%;box-sizing:border-box}
 #dlg{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.6);z-index:60;align-items:center;justify-content:center;padding:24px}
 .dlgbox{background:#22262d;border-radius:14px;padding:20px;max-width:340px;width:100%;display:flex;flex-direction:column;gap:18px}
 #dlgmsg{font-size:16px;text-align:center;line-height:1.35;word-break:break-word}
 .dlgrow{display:flex;gap:10px}
 .dlgrow button{flex:1;padding:12px;border:0;border-radius:10px;font-size:16px;font-weight:600;cursor:pointer}
 #dlgno{background:#3a3f48;color:#fff}
 #dlgyes{background:#2a7e4f;color:#fff}
 #setov{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:#111;z-index:38;flex-direction:column;overflow:hidden}
 #setbody{flex:1;display:flex;flex-direction:column;min-height:0;padding:10px;gap:10px}
 #sethint{flex:0 0 auto;color:#9aa4b2;font-size:12px;padding:0 2px}
 #set_rules{flex:1;min-height:0;width:100%;background:#0f1115;border:1px solid #3a3f48;color:#fff;border-radius:8px;padding:10px;font-size:15px;line-height:1.5;resize:none;box-sizing:border-box;font-family:inherit}
 #set_save{flex:0 0 auto;padding:13px;border:0;border-radius:10px;font-size:16px;font-weight:600;background:#2a7e4f;color:#fff;cursor:pointer}
</style></head><body>
<div id="app">
<header>
  <button class="b" id="hcog" onclick="openSettings()" style="display:none">&#9881;</button>
  <button class="b txt" id="hback" onclick="goBack()" style="display:none"></button>
  <span class="t" id="htitle">AlexEstiasis</span>
  <button class="b txt" id="hok" onclick="doOk()" style="display:none"></button>
  <button class="b" id="hright" onclick="hright()">&#8635;</button>
  <div id="amenu"><button id="m_print" onclick="doPrint()"></button><button id="m_printall" onclick="doPrintAll()"></button><button id="m_move" onclick="doMove()"></button><button id="m_addlvl" onclick="toggleMenu();addLevel()"></button><button id="m_addbill" onclick="toggleMenu();addBill()"></button><button id="m_canceldraft" onclick="cancelDraft()"></button><button id="m_close" onclick="doClose()"></button></div>
</header>
<div id="status">...</div>
<div id="grid"></div>
<div id="tv"><div id="platewrap"><div id="plates"></div><div id="qbar"><button id="qedit" onclick="openEdit()">&#9998;</button><button id="qplus" onclick="qInc()">+</button><button id="qminus" onclick="qDec()">&#8722;</button><button id="qup" onclick="qSeqUp()">&#9650;</button><button id="qdown" onclick="qSeqDown()">&#9660;</button><button id="qbill" onclick="openBillPicker()">&#8644;</button><button id="qdel" onclick="removeNote()">&#128465;</button><button id="qai" onclick="aiFill()">&#129302;</button></div></div><div id="sheetgrip"></div><div id="srch"><textarea id="psearch" class="oneline" rows="1" oninput="onSearch()" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea></div><div id="menu"></div></div>
</div>
<div id="sheet" onclick="if(event.target===this)closeSheet()"><div class="sbox">
  <div class="sh" id="sh_name"></div>
  <div class="srow"><span class="sl" id="l_qty"></span><div class="qc"><button onclick="qadj(-1)">&#8722;</button><span id="sh_qty">1</span><button onclick="qadj(1)">+</button></div></div>
  <div class="srow"><span class="sl" id="l_price"></span><span>&#8364;</span><textarea id="sh_price" class="oneline" rows="1" inputmode="decimal" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea></div>
  <div class="srow"><textarea id="sh_cmt" class="cmt oneline" rows="1" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea></div>
  <div class="srow btns"><button class="cancel" id="b_cancel" onclick="closeSheet()"></button><button class="addb" id="b_add" onclick="doAdd()"></button></div>
</div></div>
<div id="esheet" onclick="if(event.target===this)closeEdit()"><div class="sbox">
  <div class="sh" id="esh_name"></div>
  <div class="srow"><span class="sl" id="el_price"></span><span>&#8364;</span><textarea id="esh_price" class="oneline" rows="1" inputmode="decimal" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea></div>
  <div class="srow"><textarea id="esh_cmt" class="cmt oneline" rows="1" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea></div>
  <div class="srow btns"><button class="cancel" id="eb_cancel" onclick="closeEdit()"></button><button class="addb" id="eb_save" onclick="doEdit()"></button></div>
</div></div>
<div id="nsheet" onclick="if(event.target===this)closeNote()"><div class="sbox">
  <div class="sh" id="nsh_title"></div>
  <textarea id="nsh_text" autocomplete="off" autocorrect="off" autocapitalize="sentences" spellcheck="false"></textarea>
  <div class="srow btns"><button class="cancel" id="nb_cancel" onclick="closeNote()"></button><button class="addb" id="nb_save" onclick="saveNote()"></button></div>
</div></div>
<div id="lnsheet" onclick="if(event.target===this)closeSeqName()"><div class="sbox">
  <div class="sh" id="lnsh_title"></div>
  <textarea id="lnsh_text" rows="1" class="oneline" autocomplete="off" autocorrect="off" autocapitalize="sentences" spellcheck="false"></textarea>
  <div class="srow btns"><button class="cancel" id="lnb_cancel" onclick="closeSeqName()"></button><button class="addb" id="lnb_save" onclick="saveSeqName()"></button></div>
</div></div>
<div id="billsheet" onclick="if(event.target===this)closeBillPicker()"><div class="sbox"><div class="sh" id="bptitle"></div><div id="bplist"></div><div class="srow btns"><button class="cancel" id="bpcancel" onclick="closeBillPicker()"></button></div></div></div>
<div id="billedit" onclick="if(event.target===this)closeBillEdit()"><div class="sbox"><div class="sh" id="be_title"></div><textarea id="be_text" rows="1" class="oneline" autocomplete="off" autocorrect="off" autocapitalize="sentences" spellcheck="false"></textarea><div class="srow btns"><button class="cancel" id="be_cancel" onclick="closeBillEdit()"></button><button class="addb" id="be_save" onclick="saveBillName()"></button></div></div></div>
<div id="moveov"><div class="movebar"><span id="movetitle"></span><button class="mvx" onclick="closeMove()">&#10005;</button></div><div id="movegrid"></div></div>
<div id="setov"><div class="movebar"><span id="settitle"></span><button class="mvx" onclick="closeSettings()">&#10005;</button></div><div id="setbody"><div id="sethint"></div><textarea id="set_rules" spellcheck="false" autocomplete="off" autocorrect="off" autocapitalize="sentences"></textarea><button id="set_save" onclick="saveRules()"></button></div></div>
<div id="dlg"><div class="dlgbox"><div id="dlgmsg"></div><div class="dlgrow"><button id="dlgno"></button><button id="dlgyes"></button></div></div></div>
<div id="toast"></div>
<script>
 var L=__LABELS__;
 var VIEW='tables', PL=null, CUR=null, TABLES=[];
 var ICON_SEQ='data:image/png;base64,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';
 var ICON_BILL='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEgAAABICAYAAABV7bNHAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAMZSURBVHhe7ZzfT9NQFMeX+CPRBzQR/w2C+mgMMYhru3YoA/8LwrOJBubfQEx89kkewLVbGWNuRBM3o48+mCWjLWMMhlEUH0DFem+5SgLbTtl4mPb7SU5I2t1zej7cbH3oaQgAAEAoZM0NXKxnohPrmchEeebWBXEYcKq6et7Slbc/38RcHpYuF1eejZ4Tp4FjRG5sLQ27TlLx4nN+2LUT8nVxGjiJ20MfX0T/CtrMaq6tq4PiNLB1aXAzeyCovqi5VlK5KU4DCCL4pwWtJpX+2oIWr5hKwjHknK13EGz9RkbNseb7RXoPP4JsPXyVHfdyNMztM3gPa+nI81pafXT4Oo7F+5mxs5WU8ri2oP769uqu98vyKRdlwf+2FzzHzusRt5ySh0QZDz+CVoxweLcQE9fRSUS9HLwn3hvvkfcqyvjDzQ+ctpNKercw4lbMiGsbyolE893hZwcdfKZR7naC97bDemS7cj7PehalaKyEHN9l/+lGSTuJbhP0J/hGWNaVSVGqNSVTuswWbbPt1zBZJ9GtgvZ7lb9+0NVeUa45TkK592XpzpEkJxHdKogHv5MvG9KoKNccW1cebL8MniDeM/uFuy/KNYd9KB5UQZYhT4lyzWGCpoIqyNcXNQQRQBABBBFAEAEEEUAQAQQRQBABBBFAEAEEEUAQAQQRQBABBBFAEAEEEUAQAQQRQBABBBFAEAEEEUAQAQQRQBABBBFAEAEEEUAQAQQRQBABBBEwQXgErxV4iJNgOcCPAdu6HBPlmlPV1V621QL5IPnq7OAlUa41/MsqaKMITNBDUYqGD3Y4hmLyhav/8TAL740Ps7CcKXdm7JQo5Q8+IlQ1I9Ns++3x0aGtjseQ9sehuHSnzXGo78WTGIca9noR41B7lWRk+t2Ta2dEmeNTMbW+9bQ6yWzPsYvPWkb7wddvLGpZ1vyxB+osU7pSz2pejka5/QZfvzavzq5n1MlKQuoT6bsbP4ICDQQRQBABXixAUMarKVqz/3ITufhDvNyE3agW8HKTQ5RMqYfdAozX0tp46anUIw4DAECACYV+A6l+HDilbzNfAAAAAElFTkSuQmCC';
 function esc(s){return (s==null?'':s.toString()).replace(/[&<>]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
 function safeColor(c){ return (typeof c==='string' && /^#?[0-9a-fA-F]{3,8}$/.test(c))? c : '#0000FF'; }
 function money(n){return String.fromCharCode(8364)+(Number(n)||0).toFixed(2);}
 function fmtQ(q){q=Number(q)||0;return (q%1===0?q.toFixed(0):(''+q))+'x';}
 function flash(m){var t=document.getElementById('toast');t.textContent=m;t.style.display='block';clearTimeout(window._ft);window._ft=setTimeout(function(){t.style.display='none';},1800);}
 function confirmDlg(msg,onYes){ var d=document.getElementById('dlg'); document.getElementById('dlgmsg').textContent=msg; var no=document.getElementById('dlgno'), yes=document.getElementById('dlgyes'); no.style.display=''; no.textContent=L.cancel; yes.textContent=L.ok; d.style.display='flex'; no.onclick=function(){ d.style.display='none'; }; yes.onclick=function(){ d.style.display='none'; if(onYes)onYes(); }; }
 function alertDlg(msg){ var d=document.getElementById('dlg'); document.getElementById('dlgmsg').textContent=msg; document.getElementById('dlgno').style.display='none'; var yes=document.getElementById('dlgyes'); yes.textContent=L.ok; d.style.display='flex'; yes.onclick=function(){ d.style.display='none'; document.getElementById('dlgno').style.display=''; }; }
 function applyLabels(){
   document.getElementById('l_qty').textContent=L.qty; document.getElementById('l_price').textContent=L.price;
   document.getElementById('sh_cmt').placeholder=L.comment; document.getElementById('b_cancel').textContent=L.cancel;
   document.getElementById('b_add').textContent=L.add; document.getElementById('m_print').textContent=L.print; document.getElementById('m_close').textContent=L.close;
   document.getElementById('hback').textContent=L.back; document.getElementById('hok').textContent=L.ok;
   document.getElementById('m_canceldraft').textContent=L.cancelDraft;
   document.getElementById('m_move').textContent=L.move; document.getElementById('m_printall').textContent=L.printAll; document.getElementById('m_addlvl').textContent=L.addLevel; document.getElementById('m_addbill').textContent=L.addBill;
   document.getElementById('psearch').placeholder=L.search;
   document.getElementById('el_price').textContent=L.price; document.getElementById('esh_cmt').placeholder=L.comment;
   document.getElementById('eb_cancel').textContent=L.cancel; document.getElementById('eb_save').textContent=L.ok;
   document.getElementById('nb_cancel').textContent=L.cancel; document.getElementById('nb_save').textContent=L.ok;
   document.getElementById('lnb_cancel').textContent=L.cancel; document.getElementById('lnb_save').textContent=L.ok;
   document.getElementById('nsh_text').placeholder=L.notePlaceholder;
   document.getElementById('settitle').textContent=L.rulesTitle; document.getElementById('sethint').textContent=L.rulesHint; document.getElementById('set_save').textContent=L.ok;
 }
 function goBack(){
   if(!CUR){ showTables(); return; }
   var tid=CUR.id; var body=JSON.stringify(CUR.pending||[]);
   fetch('/api/draft?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:body}).then(function(r){ if(!r||!r.ok)flash(L.error); }).catch(function(){ flash(L.error); });
   showTables();
 }
 function withFreshOrder(proceed){
   // Refetch the live committed Estiasis order (changed by ANY client: our app, the old Estiasis app, or the
   // desktop POS), adopt it so our commit rebases onto the truth incl. the current Order_ID, and warn before
   // proceeding if it changed externally OR the shared draft was co-edited by another phone.
   if(window.OKGUARD)return;                                            // re-entrancy: a guard fetch is already in flight
   if(document.getElementById('dlg').style.display==='flex')return;     // a confirm dialog is already open
   window.OKGUARD=true;
   var ac=('AbortController' in window)?new AbortController():null;
   var to=setTimeout(function(){ if(ac){ try{ac.abort();}catch(e){} } },8000);   // never let a stalled fetch wedge OKGUARD
   var clear=function(){ clearTimeout(to); window.OKGUARD=false; };
   fetch('/api/order?table='+CUR.id,{signal:ac?ac.signal:undefined}).then(function(r){return r.json();}).then(function(live){
     clear();
     if(!CUR){ return; }
     var pre=CUR.order; var liveSig=orderSig(live);
     var changed=(!!CUR._extChanged)||(!!CUR._draftCoEdited)||(CUR._osig!=null&&liveSig!==CUR._osig);
     var hasPendNow=!!(CUR.pending&&CUR.pending.length);
     // adopt the live truth and CONSUME the conflict flags now (we are showing/acting on the current state),
     // so cancelling the warning cannot leave the flags set and re-warn forever.
     CUR.order=live; CUR._osig=liveSig; CUR._extChanged=false; CUR._draftCoEdited=false; CUR.sel=null; renderPlates(live);
     var proceed2=function(){ if(CUR)proceed(); };
     if(hasPendNow&&changed){ var msg=L.parallelConfirm; var dm=orderDiffMsg(pre,live); if(dm)msg+=' '+dm; confirmDlg(msg, proceed2); }
     else { proceed2(); }
   }).catch(function(){ clear(); confirmDlg(L.verifyFail, function(){ if(CUR)proceed(); }); });
 }
 function doOk(){
   withFreshOrder(function(){ commit().then(function(){ showTables(); }).catch(function(e){ alertDlg(L.error+': '+e); if(CUR)renderPlates(CUR.order); }); });
 }
 function cancelDraft(){ toggleMenu(); confirmDlg(L.cancelDraftConfirm, function(){
   if(!CUR){ showTables(); return; }
   var tid=CUR.id;
   var keep=(CUR.notes||[]).filter(function(n){ return n&&n.ok; });
   var nraw=keep.length?JSON.stringify(keep):'';
   CUR.pending=[]; CUR.sel=null; CUR.notes=keep; CUR._nraw=nraw;
   var keepL={}; var cmax=1; ((CUR.order&&CUR.order.orderProducts)?CUR.order.orderProducts:[]).forEach(function(l){ if(!l.extraOf_ID){ var lv=Number(l.courseSeq)||1; keepL[lv]=1; if(lv>cmax)cmax=lv; } }); keep.forEach(function(n){ var lv=Number(n.seq)||1; keepL[lv]=1; if(lv>cmax)cmax=lv; });
   if(CUR.lnames){ for(var lk in CUR.lnames){ if(!keepL[parseInt(lk,10)]) delete CUR.lnames[lk]; } }
   CUR.maxLevel=cmax; persistSeqNames();
   var cmaxB=0; ((CUR.order&&CUR.order.orderProducts)?CUR.order.orderProducts:[]).forEach(function(l){ if(!l.extraOf_ID){ var bn=Number(l.billNumber)||0; if(bn>cmaxB)cmaxB=bn; } }); keep.forEach(function(n){ var bn=Number(n.bill)||0; if(bn>cmaxB)cmaxB=bn; }); if(CUR.bnames){ for(var bk in CUR.bnames){ if(parseInt(bk,10)>cmaxB) delete CUR.bnames[bk]; } } CUR.maxBill=cmaxB; CUR.bill=0; CUR.billOk=(cmaxB>=1); persistBillMeta();
   fetch('/api/note?table='+tid,{method:'POST',headers:{'Content-Type':'text/plain; charset=utf-8'},body:nraw}).catch(function(){});
   saveDraft();
   showTables();
 }); }
 function hright(){ if(VIEW==='tables') loadTables(); else toggleMenu(); }
 function hasDraftNote(){ if(!CUR||!CUR.notes)return false; for(var i=0;i<CUR.notes.length;i++){ if(CUR.notes[i]&&!CUR.notes[i].ok)return true; } return false; }
 function toggleMenu(){ var m=document.getElementById('amenu'); var show=(m.style.display!=='block'); if(show){ document.getElementById('m_canceldraft').style.display=((CUR&&CUR.pending&&CUR.pending.length)||hasDraftNote()||(CUR&&(CUR.maxLevel||1)>1&&!CUR.seqOk)||(CUR&&(CUR.maxBill||0)>=1&&!CUR.billOk))?'block':'none'; var ba=!!(CUR&&(CUR.maxBill||0)>0); document.getElementById('m_print').textContent=ba?L.printCurrent:L.print; document.getElementById('m_printall').style.display=ba?'block':'none'; } m.style.display=show?'block':'none'; }
 function showTables(){ VIEW='tables'; CUR=null; document.getElementById('amenu').style.display='none';
   document.getElementById('grid').style.display=''; document.getElementById('status').style.display=''; document.getElementById('tv').style.display='none';
   document.getElementById('hback').style.display='none'; document.getElementById('hok').style.display='none'; document.getElementById('hcog').style.display='';
   document.getElementById('hright').innerHTML='&#8635;'; document.getElementById('htitle').textContent='AlexEstiasis'; loadTables(); }
 function loadTables(){
   document.getElementById('status').textContent='...';
   Promise.all([
     fetch('/api/tables').then(function(r){return r.json();}),
     fetch('/api/drafts').then(function(r){return r.json();}).catch(function(){return [];})
   ]).then(function(res){
     if(!Array.isArray(res[0])){ document.getElementById('status').textContent=L.error; document.getElementById('grid').innerHTML=''; return; }
     var tables=res[0]; var dr=res[1]||{}; var dl=Array.isArray(dr)?dr:(Array.isArray(dr.d)?dr.d:[]); var ol=(dr&&Array.isArray(dr.o))?dr.o:[];
     var dset={}; dl.forEach(function(id){ dset[id]=true; });
     var oset={}; ol.forEach(function(id){ oset[id]=true; });
     // Drop stale note/serving-order metadata when a table's order was closed elsewhere (e.g. the old Estiasis app).
     // We remember (in localStorage) any table we saw carrying our metadata WHILE it had an order; if that order later
     // vanishes, the leftover note/seq is from that closed session -> clear it so it stops showing orange. A note on a
     // table that never had an order (the intentional orange case) has no binding and is kept.
     try{ var _bind=JSON.parse(localStorage.getItem('estbind')||'{}'); var _bch=false;
       tables.forEach(function(t){ var id=t.table_ID;
         if(t.order_ID){ if((oset[id]||dset[id])&&!_bind[id]){ _bind[id]=1; _bch=true; } }
         else if(_bind[id]){ if(oset[id]){ fetch('/api/note?table='+id,{method:'POST',headers:{'Content-Type':'text/plain'},body:''}).catch(function(){}); fetch('/api/seqnames?table='+id,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).catch(function(){}); delete oset[id]; } delete _bind[id]; _bch=true; }
       });
       if(_bch)localStorage.setItem('estbind',JSON.stringify(_bind));
     }catch(e){}
     TABLES=tables;
     tables.sort(function(a,b){var sa=(a.sort==null||a.sort===''?1e9:Number(a.sort)),sb=(b.sort==null||b.sort===''?1e9:Number(b.sort));if(isNaN(sa))sa=1e9;if(isNaN(sb))sb=1e9;return sa-sb||(a.description||'').localeCompare(b.description||'');});
     var ghtml=tables.map(function(t){
       var color=dset[t.table_ID]?'#2a8a4a':(t.order_ID?'#FF0000':(oset[t.table_ID]?'#FFA500':safeColor(t.colorHex)));
       return '<div class="tile" style="background:'+esc(color)+'" onclick="openTable('+t.table_ID+')">'+esc(t.description)+'</div>';
     }).join('');
     if(ghtml!==window._gh){ document.getElementById('grid').innerHTML=ghtml; window._gh=ghtml; }
     var open=tables.filter(function(t){return t.order_ID||dset[t.table_ID]||oset[t.table_ID];}).length;
     document.getElementById('status').textContent=tables.length+' '+L.tables+', '+open+' '+L.open;
   }).catch(function(e){document.getElementById('status').textContent='error: '+e;});
 }
 function openTable(id){
   var t=TABLES.filter(function(x){return x.table_ID===id;})[0]||{table_ID:id,description:''+id,serviceArea_ID:1};
   VIEW='table'; CUR={id:id,desc:t.description,areaId:t.serviceArea_ID,order:null,pending:[],seq:0,sel:null,notes:[],level:1,maxLevel:1,lnames:{},seqOk:false,bill:0,maxBill:0,bnames:{},billOk:false,_extChanged:false,_draw:'',_dsaving:0,_draftCoEdited:false};
   document.getElementById('amenu').style.display='none';
   document.getElementById('grid').style.display='none'; document.getElementById('status').style.display='none'; document.getElementById('tv').style.display='flex'; var _pw=document.getElementById('platewrap'); if(_pw){ _pw.style.transition=''; _pw.style.height='38vh'; }
   document.getElementById('hback').style.display=''; document.getElementById('hok').style.display=''; document.getElementById('hcog').style.display='none';
   document.getElementById('hright').innerHTML='&#8942;'; document.getElementById('htitle').textContent=t.description+' ...';
   document.getElementById('plates').innerHTML='<div id="pempty">...</div>';
   document.getElementById('psearch').value=''; fetchOrder(); menuCategories();
 }
 function fetchOrder(){
   Promise.all([
     fetch('/api/order?table='+CUR.id).then(function(r){return r.json();}).catch(function(){return null;}),
     fetch('/api/draft?table='+CUR.id).then(function(r){return r.json();}).catch(function(){return [];}),
     fetch('/api/note?table='+CUR.id).then(function(r){return r.text();}).catch(function(){return '';}),
     fetch('/api/seqnames?table='+CUR.id).then(function(r){return r.json();}).catch(function(){return {};}),
     fetch('/api/billmeta?table='+CUR.id).then(function(r){return r.json();}).catch(function(){return {};})
   ]).then(function(res){ CUR.order=res[0]; CUR.pending=Array.isArray(res[1])?res[1]:[]; CUR._nraw=res[2]||''; CUR.notes=parseNotes(res[2]); var sm=(res[3]&&typeof res[3]==='object')?res[3]:{}; if(sm.names||typeof sm.max!=='undefined'){ CUR.lnames=(sm.names&&typeof sm.names==='object')?sm.names:{}; CUR.maxLevel=Math.max(1,Number(sm.max)||1); } else { CUR.lnames=sm; CUR.maxLevel=1; } CUR.seqOk=(sm.ok===true); var bm=(res[4]&&typeof res[4]==='object')?res[4]:{}; CUR.bnames=(bm.names&&typeof bm.names==='object')?bm.names:{}; CUR.maxBill=Math.max(0,Number(bm.max)||0); CUR.billOk=(bm.ok===true); CUR.bill=0; CUR.sel=null; CUR.seq=0; CUR.pending.forEach(function(l,i){ l._id=++CUR.seq; if(!l._ts)l._ts=Date.now()+i; }); CUR._osig=orderSig(CUR.order); CUR._extChanged=false; CUR._draw=draftSig(CUR.pending); CUR._dsaving=0; CUR._draftCoEdited=false; renderPlates(CUR.order); })
    .catch(function(){ renderPlates(null); });
 }
 function renderPlates(order){
   var p=document.getElementById('plates');
   var qb=document.getElementById('qbar'); var sr=(CUR&&CUR.sel)?selRow():null;
   var saved=(order&&order.orderProducts)?order.orderProducts:[];
   var pend=CUR.pending||[];
   var notes=(CUR&&CUR.notes)?CUR.notes:[];
   var editMap={}; pend.forEach(function(l){ if(l&&l._edit&&l.OrderLine_ID!=null)editMap[l.OrderLine_ID]=l; });
   var total=0; saved.forEach(function(l){ var e=editMap[l.orderLine_ID]; total+=e?(Number(e.Value)||0):(Number(l.value)||0); }); pend.forEach(function(l){ if(l._edit)return; total+=Number(l.Value)||0; });
   document.getElementById('htitle').textContent=CUR.desc+' ('+money(total)+')';
   if(!CUR.level||CUR.level<1)CUR.level=1;
   var tops=saved.filter(function(l){return !l.extraOf_ID;});
   var rows=[];
   var lastTs=0; tops.forEach(function(l,i){ var ts=Date.parse(l.timeOrdered); if(isNaN(ts))ts=lastTs; else lastTs=ts; rows.push({k:'c',ts:ts,ord:i,l:l,edit:editMap[l.orderLine_ID]||null,lvl:Number(l.courseSeq)||1,bill:Number(l.billNumber)||0}); });
   pend.forEach(function(l,i){ if(l._edit)return; rows.push({k:'p',ts:(Number(l._ts)||0),ord:1000000+i,l:l,lvl:Number(l.CourseSeq)||1,bill:Number(l.BillNumber)||0}); });
   notes.forEach(function(n,ni){ rows.push({k:'note',ts:(Number(n.ts)||0),ord:2000000+ni,n:n,ni:ni,lvl:Number(n.seq)||1,bill:Number(n.bill)||0}); });
   var used=1; rows.forEach(function(r){ if(r.lvl>used)used=r.lvl; });
   if(!CUR.maxLevel||CUR.maxLevel<used)CUR.maxLevel=used;
   var maxL=Math.max(used,CUR.level,CUR.maxLevel); CUR.maxLevel=maxL; if(CUR.level>maxL)CUR.level=maxL;
   var usedBill=0; rows.forEach(function(r){ if(r.bill>usedBill)usedBill=r.bill; });
   var maxBill=Math.max(usedBill,CUR.maxBill||0); CUR.maxBill=maxBill; if((CUR.bill||0)>maxBill)CUR.bill=maxBill; if(!CUR.bill||CUR.bill<0)CUR.bill=0;
   var billsActive=(maxBill>=1);
   var multi=(maxL>=2);
   var showHdr=multi;
   if(sr){ qb.style.display='flex'; document.getElementById('qedit').style.display='block'; var isN=(sr.k==='note'); document.getElementById('qplus').style.display=isN?'none':''; document.getElementById('qminus').style.display=isN?'none':''; document.getElementById('qdel').style.display=isN?'block':'none'; document.getElementById('qai').style.display=isN?'block':'none'; document.getElementById('qup').style.display=multi?'block':'none'; document.getElementById('qdown').style.display=multi?'block':'none'; document.getElementById('qbill').style.display=billsActive?'block':'none'; } else { qb.style.display='none'; }
   function rowHtml(r){
     if(r.k==='note'){ var ni=r.ni; var ncls=(r.n&&r.n.ok)?'':' ndraft'; return '<div class="pl note'+ncls+((CUR.sel&&CUR.sel.kind==='note'&&CUR.sel.ref===ni)?' sel':'')+'" onclick="selectRow(\'note\','+ni+')"><div class="ntext">'+esc(r.n.t)+'</div></div>'; }
     if(r.k==='c'){ var l=r.l; var ed=r.edit;
       var extras=saved.filter(function(x){return x.extraOf_ID===l.orderLine_ID;});
       var ex=extras.map(function(e){return '<div class="pl ext"><span class="q">'+fmtQ(e.quantity)+'</span><span class="n">'+esc(e.description)+'</span><span class="v">'+money(e.value)+'</span></div>';}).join('');
       var cmtTxt=ed?ed.Comments:l.comments; var cmt=cmtTxt?'<div class="cmt">'+esc(cmtTxt)+'</div>':'';
       var cls=(Number(l.quantity)||0)<0?' neg':''; if(ed)cls+=' pend'; if(CUR.sel&&CUR.sel.kind==='c'&&CUR.sel.ref===l.orderLine_ID)cls+=' sel';
       return '<div class="pl'+cls+'" onclick="selectRow(\'c\','+l.orderLine_ID+')"><span class="q">'+fmtQ(l.quantity)+'</span><span class="n">'+esc(l.description)+cmt+'</span><span class="v">'+money(ed?ed.Value:l.value)+'</span></div>'+ex;
     }
     var pl=r.l;
     var cmt=pl.Comments?'<div class="cmt">'+esc(pl.Comments)+'</div>':'';
     var cls=' pend'; if((Number(pl.Quantity)||0)<0)cls+=' neg'; if(CUR.sel&&CUR.sel.kind==='p'&&CUR.sel.ref===pl._id)cls+=' sel';
     return '<div class="pl'+cls+'" onclick="selectRow(\'p\','+pl._id+')"><span class="q">'+fmtQ(pl.Quantity)+'</span><span class="n">'+esc(pl.Description)+cmt+'</span><span class="v">'+money(pl.Value)+'</span></div>';
   }
   var h='';
   if(billsActive){
     var btot=0; rows.forEach(function(r){ if(r.bill===CUR.bill){ if(r.k==='c'){ btot+=r.edit?(Number(r.edit.Value)||0):(Number(r.l.value)||0); } else if(r.k==='p'){ btot+=Number(r.l.Value)||0; } } });
     var bnm=(CUR.bnames&&CUR.bnames[CUR.bill]!=null)?(''+CUR.bnames[CUR.bill]):''; var blbl=bnm?bnm:((CUR.bill===0)?L.billMain:(L.billHeader+' '+CUR.bill));
     h+='<div class="billbar"><span class="billnav" onclick="prevBill()">&#9664;</span><span class="billlbl">'+esc(blbl)+'<span class="billdel" onclick="event.stopPropagation();deleteBillStart('+CUR.bill+')">&#128465;</span><span class="billedit" onclick="event.stopPropagation();openBillEdit('+CUR.bill+')">&#9998;</span></span><span class="billtot">'+money(btot)+'</span><span class="billnav" onclick="nextBill()">&#9654;</span></div>';
     rows=rows.filter(function(r){ return r.bill===CUR.bill; });
   }
   if(!rows.length && !showHdr){ h+='<div id="pempty">'+L.empty+'</div>'; }
   else { var byLvl={}; rows.forEach(function(r){ (byLvl[r.lvl]=byLvl[r.lvl]||[]).push(r); });
     for(var lv=1; lv<=maxL; lv++){
       var grp=byLvl[lv]||[]; grp.sort(function(a,b){ return (a.ts-b.ts)||(a.ord-b.ord); });
       if(showHdr){ var nm=(CUR.lnames&&CUR.lnames[lv]!=null)?(''+CUR.lnames[lv]):''; var htx=nm?(lv+'. '+esc(nm)):(esc(L.seqHeader)+' '+lv); var hdr='<div class="lvlhdr'+(lv===CUR.level?' act':'')+'" onclick="setLevel('+lv+')"><span class="lvln">'+htx+'</span><span class="lvldel" onclick="event.stopPropagation();deleteLevelConfirm('+lv+')">&#128465;</span><span class="lvledit" onclick="event.stopPropagation();openSeqName('+lv+')">&#9998;</span></div>'; var body=grp.length?grp.map(rowHtml).join(''):('<div class="lvlempty">'+esc(L.empty)+'</div>'); h+='<div class="lvlsec">'+hdr+body+'</div>'; }
       else { h+=grp.map(rowHtml).join(''); }
     }
   }
   p.innerHTML=h;
 }
 function usedMaxLevel(){ var m=1; savedLines().forEach(function(l){ if(!l.extraOf_ID){ var v=Number(l.courseSeq)||1; if(v>m)m=v; } }); (CUR.pending||[]).forEach(function(l){ var v=Number(l.CourseSeq)||1; if(v>m)m=v; }); (CUR.notes||[]).forEach(function(n){ var v=Number(n.seq)||1; if(v>m)m=v; }); return m; }
 function displayMax(){ return Math.max(usedMaxLevel(), CUR.level||1, CUR.maxLevel||1); }
 function selLevel(){ if(!CUR.sel)return CUR.level||1; if(CUR.sel.kind==='note'){ var n=CUR.notes&&CUR.notes[CUR.sel.ref]; return n?(Number(n.seq)||1):(CUR.level||1); } if(CUR.sel.kind==='p'){ var l=findPending(CUR.sel.ref); return l?(Number(l.CourseSeq)||1):(CUR.level||1); } var s=savedLines().filter(function(x){return x.orderLine_ID===CUR.sel.ref;})[0]; return s?(Number(s.courseSeq)||1):(CUR.level||1); }
 function setLevel(n){ CUR.level=n; renderPlates(CUR.order); }
 function deleteLevelConfirm(n){ confirmDlg(L.seqDelConfirm, function(){ deleteLevel(n); }); }
 function deleteLevel(n){ var map=function(L){ L=Number(L)||1; if(L<n)return L; if(L===n)return (n>1?n-1:1); return L-1; };
   var applyLocal=function(){
     (CUR.pending||[]).forEach(function(l){ l.CourseSeq=map(Number(l.CourseSeq)||1); }); if(CUR.pending&&CUR.pending.length)saveDraft();
     (CUR.notes||[]).forEach(function(nn){ nn.seq=map(Number(nn.seq)||1); }); if(CUR.notes&&CUR.notes.length)saveNotes();
     var nn2={}; if(CUR.lnames){ var keys=[]; for(var k in CUR.lnames){ var ki=parseInt(k,10); if(ki>=1)keys.push(ki); } keys.sort(function(a,b){return a-b;}); keys.forEach(function(L){ var v=CUR.lnames[L]; if(v){ var t=map(L); if(!nn2[t])nn2[t]=v; } }); }
     CUR.lnames=nn2;
     CUR.level=map(CUR.level); if(CUR.maxLevel)CUR.maxLevel=Math.max(1,CUR.maxLevel-1); CUR.sel=null; persistSeqNames();
   };
   var saved=(CUR.order&&CUR.order.orderProducts)?CUR.order.orderProducts:[];
   var changed=[]; saved.forEach(function(s){ if(s.extraOf_ID)return; var ov=Number(s.courseSeq)||1; var nv=map(ov); if(nv!==ov){ var line=mkModified(s,Number(s.price)||0,(s.comments||null)); line.CourseSeq=nv; changed.push(line); } });
   if(changed.length){ var ord=CUR.order; var order={Order_ID:ord.order_ID,TradingPeriod_ID:-1,Employee_ID:0,ServiceArea_ID:ord.serviceArea_ID,Table_ID:CUR.id,Guests:0,PriceList_ID:PL.defaultPriceList,Customer_ID:null,CustomerName:null,CustomerDiscount:null,TimeOpen:null,TimeBilled:null,TimePayed:null,Comments:null,LastChanged:null,ExternalId:null,OrderProducts:changed,OrdersOrder:[],TrackingState:0,EntityIdentifier:'00000000-0000-0000-0000-000000000000'};
     flash(L.saving);
     fetch('/api/save?pricelistId='+PL.defaultPriceList,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify([order])})
       .then(function(rr){ if(!rr.ok) throw new Error('save '+rr.status); return rr.text(); })
       .then(function(){ return fetch('/api/order?table='+CUR.id).then(function(x){return x.json();}); })
       .then(function(o){ CUR.order=o; applyLocal(); CUR._osig=orderSig(o); renderPlates(o); })
       .catch(function(e){ alertDlg(L.error+': '+e); renderPlates(CUR.order); });
   } else { applyLocal(); renderPlates(CUR.order); } }
 function addLevel(){ CUR.maxLevel=Math.max(usedMaxLevel(),CUR.maxLevel||1)+1; CUR.level=CUR.maxLevel; CUR.sel=null; CUR.seqOk=false; persistSeqNames(); renderPlates(CUR.order); }
 function persistSeqNames(){ var tid=CUR.id; var names=CUR.lnames||{}; var hasN=false; for(var k in names){ if(names[k]&&(''+names[k]).trim())hasN=true; } var mx=Math.max(1,CUR.maxLevel||1); var body=(mx>1||hasN)?JSON.stringify({max:mx,names:names,ok:!!CUR.seqOk}):'{}'; fetch('/api/seqnames?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:body}).catch(function(){}); }
 function persistBillMeta(){ var tid=CUR.id; var names=CUR.bnames||{}; var hasN=false; for(var k in names){ if(names[k]&&(''+names[k]).trim())hasN=true; } var mx=Math.max(0,CUR.maxBill||0); var body=(mx>=1||hasN)?JSON.stringify({max:mx,names:names,ok:!!CUR.billOk}):'{}'; fetch('/api/billmeta?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:body}).catch(function(){}); }
 function openSeqName(n){ window.LNIDX=n; document.getElementById('lnsh_title').textContent=L.seqHeader+' '+n; document.getElementById('lnsh_text').value=(CUR.lnames&&CUR.lnames[n]!=null)?CUR.lnames[n]:''; document.getElementById('lnsheet').style.display='flex'; setTimeout(function(){ try{document.getElementById('lnsh_text').focus();}catch(e){} },60); }
 function closeSeqName(){ document.getElementById('lnsheet').style.display='none'; }
 function saveSeqName(){ var n=window.LNIDX; var v=(document.getElementById('lnsh_text').value||'').trim(); if(!CUR.lnames)CUR.lnames={}; if(v)CUR.lnames[n]=v; else delete CUR.lnames[n]; closeSeqName(); persistSeqNames(); renderPlates(CUR.order); }
 function moveSeq(dir){ var r=selRow(); if(!r){ flash(L.selectItem); return; } var cur=(r.k==='note')?(Number(CUR.notes[r.i].seq)||1):((r.k==='p')?(Number(r.l.CourseSeq)||1):(Number(r.l.courseSeq)||1)); var nl=cur+dir; if(nl<1)nl=1; var hi=displayMax(); if(nl>hi)nl=hi; if(nl===cur)return;
   if(r.k==='note'){ CUR.notes[r.i].seq=nl; CUR.level=nl; saveNotes(); renderPlates(CUR.order); }
   else if(r.k==='p'){ r.l.CourseSeq=nl; CUR.level=nl; saveDraft(); renderPlates(CUR.order); }
   else { changeCommittedSeq(r.l,nl); } }
 function qSeqUp(){ moveSeq(-1); }
 function qSeqDown(){ moveSeq(1); }
 function changeCommittedSeq(s,newSeq){ var prev=CUR.level; var line=mkModified(s,Number(s.price)||0,(s.comments||null)); line.CourseSeq=newSeq; var ord=CUR.order;
   var order={Order_ID:ord.order_ID,TradingPeriod_ID:-1,Employee_ID:0,ServiceArea_ID:ord.serviceArea_ID,Table_ID:CUR.id,Guests:0,PriceList_ID:PL.defaultPriceList,Customer_ID:null,CustomerName:null,CustomerDiscount:null,TimeOpen:null,TimeBilled:null,TimePayed:null,Comments:null,LastChanged:null,ExternalId:null,OrderProducts:[line],OrdersOrder:[],TrackingState:0,EntityIdentifier:'00000000-0000-0000-0000-000000000000'};
   flash(L.saving);
   fetch('/api/save?pricelistId='+PL.defaultPriceList,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify([order])})
     .then(function(rr){ if(!rr.ok) throw new Error('save '+rr.status); return rr.text(); })
     .then(function(){ return fetch('/api/order?table='+CUR.id).then(function(x){return x.json();}); })
     .then(function(o){ CUR.order=o; CUR.level=newSeq; CUR._osig=orderSig(o); renderPlates(o); })
     .catch(function(e){ CUR.level=prev; alertDlg(L.error+': '+e); renderPlates(CUR.order); }); }
 function usedMaxBill(){ var m=0; savedLines().forEach(function(l){ if(!l.extraOf_ID){ var v=Number(l.billNumber)||0; if(v>m)m=v; } }); (CUR.pending||[]).forEach(function(l){ var v=Number(l.BillNumber)||0; if(v>m)m=v; }); (CUR.notes||[]).forEach(function(n){ var v=Number(n.bill)||0; if(v>m)m=v; }); return m; }
 function billLabel(b){ var nm=(CUR.bnames&&CUR.bnames[b]!=null)?(''+CUR.bnames[b]):''; return nm?nm:((b===0)?L.billMain:(L.billHeader+' '+b)); }
 function addBill(){ CUR.maxBill=Math.max(usedMaxBill(),CUR.maxBill||0)+1; CUR.sel=null; CUR.billOk=false; persistBillMeta(); renderPlates(CUR.order); }
 function prevBill(){ var mx=Math.max(usedMaxBill(),CUR.maxBill||0); var b=(CUR.bill||0)-1; if(b<0)b=mx; CUR.bill=b; CUR.sel=null; renderPlates(CUR.order); }
 function nextBill(){ var mx=Math.max(usedMaxBill(),CUR.maxBill||0); var b=(CUR.bill||0)+1; if(b>mx)b=0; CUR.bill=b; CUR.sel=null; renderPlates(CUR.order); }
 function openBillPicker(){ var r=selRow(); if(!r){ flash(L.selectItem); return; } var mx=Math.max(usedMaxBill(),CUR.maxBill||0); var cur=(r.k==='note')?((CUR.notes[r.i])?(Number(CUR.notes[r.i].bill)||0):0):((r.k==='p')?(Number(r.l.BillNumber)||0):(Number(r.l.billNumber)||0)); var h=''; for(var b=0;b<=mx;b++){ var lbl=billLabel(b); h+='<button class="billpick'+(b===cur?' cur':'')+'" onclick="moveBillTo('+b+')">'+esc(lbl)+'</button>'; } document.getElementById('bptitle').textContent=L.billMove; document.getElementById('bpcancel').textContent=L.cancel; document.getElementById('bplist').innerHTML=h; document.getElementById('billsheet').style.display='flex'; }
 function closeBillPicker(){ document.getElementById('billsheet').style.display='none'; }
 function moveBillTo(b){ var r=selRow(); closeBillPicker(); if(!r)return; if(r.k==='note'){ if(CUR.notes&&CUR.notes[r.i])CUR.notes[r.i].bill=b; CUR.sel=null; saveNotes(); renderPlates(CUR.order); return; } if(r.k==='p'){ r.l.BillNumber=b; CUR.sel=null; saveDraft(); renderPlates(CUR.order); } else { changeCommittedBill(r.l,b); } }
 function changeCommittedBill(s,b){ var line=mkModified(s,Number(s.price)||0,(s.comments||null)); line.BillNumber=b; var ord=CUR.order;
   var order={Order_ID:ord.order_ID,TradingPeriod_ID:-1,Employee_ID:0,ServiceArea_ID:ord.serviceArea_ID,Table_ID:CUR.id,Guests:0,PriceList_ID:PL.defaultPriceList,Customer_ID:null,CustomerName:null,CustomerDiscount:null,TimeOpen:null,TimeBilled:null,TimePayed:null,Comments:null,LastChanged:null,ExternalId:null,OrderProducts:[line],OrdersOrder:[],TrackingState:0,EntityIdentifier:'00000000-0000-0000-0000-000000000000'};
   flash(L.saving);
   fetch('/api/save?pricelistId='+PL.defaultPriceList,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify([order])})
     .then(function(rr){ if(!rr.ok) throw new Error('save '+rr.status); return rr.text(); })
     .then(function(){ return fetch('/api/order?table='+CUR.id).then(function(x){return x.json();}); })
     .then(function(o){ CUR.order=o; CUR.sel=null; CUR._osig=orderSig(o); renderPlates(o); })
     .catch(function(e){ alertDlg(L.error+': '+e); renderPlates(CUR.order); }); }
 function openBillEdit(n){ window.BEIDX=n; document.getElementById('be_title').textContent=billLabel(n); document.getElementById('be_text').value=(CUR.bnames&&CUR.bnames[n]!=null)?CUR.bnames[n]:''; document.getElementById('be_cancel').textContent=L.cancel; document.getElementById('be_save').textContent=L.ok; document.getElementById('billedit').style.display='flex'; setTimeout(function(){ try{document.getElementById('be_text').focus();}catch(e){} },60); }
 function closeBillEdit(){ document.getElementById('billedit').style.display='none'; }
 function saveBillName(){ var n=window.BEIDX; var v=(document.getElementById('be_text').value||'').trim(); if(!CUR.bnames)CUR.bnames={}; if(v)CUR.bnames[n]=v; else delete CUR.bnames[n]; closeBillEdit(); persistBillMeta(); renderPlates(CUR.order); }
 function billHasDishes(n){ var has=false; savedLines().forEach(function(s){ if(!s.extraOf_ID&&(Number(s.billNumber)||0)===n)has=true; }); (CUR.pending||[]).forEach(function(l){ if((Number(l.BillNumber)||0)===n)has=true; }); return has; }
 function billHasNotes(n){ var has=false; (CUR.notes||[]).forEach(function(nt){ if((Number(nt.bill)||0)===n)has=true; }); return has; }
 function deleteBillStart(n){ if(n==null)n=window.BEIDX; closeBillEdit(); if(!billHasDishes(n)&&!billHasNotes(n)){ removeBill(n,'del',0); return; }
   var mx=Math.max(usedMaxBill(),CUR.maxBill||0); var h='<button class="billpick" onclick="removeBill('+n+',\'del\',0)">'+esc(L.billDelDishes)+'</button>';
   for(var b=0;b<=mx;b++){ if(b===n)continue; var lbl=billLabel(b); h+='<button class="billpick" onclick="removeBill('+n+',\'xfer\','+b+')">'+esc(L.billXfer)+' '+esc(lbl)+'</button>'; }
   document.getElementById('bptitle').textContent=L.billDelConfirm; document.getElementById('bpcancel').textContent=L.cancel; document.getElementById('bplist').innerHTML=h; document.getElementById('billsheet').style.display='flex'; }
 function removeBill(n,mode,target){ closeBillPicker();
   var shift=function(b){ b=Number(b)||0; return b<n?b:(b>n?(b-1):b); };
   var tgt=(mode==='xfer')?shift(target):0;
   var applyLocal=function(){
     if(mode==='del'){ CUR.pending=(CUR.pending||[]).filter(function(l){ return !l._delx; }); }
     (CUR.pending||[]).forEach(function(l){ var ob=Number(l.BillNumber)||0; l.BillNumber=(ob===n)?tgt:shift(ob); });
     var kn=[]; (CUR.notes||[]).forEach(function(nt){ var ob=Number(nt.bill)||0; if(ob===n){ if(mode==='xfer'){ nt.bill=tgt; kn.push(nt); } } else { nt.bill=shift(ob); kn.push(nt); } }); CUR.notes=kn; saveNotes();
     var nn={}; for(var k in (CUR.bnames||{})){ var ki=parseInt(k,10); if(ki>=1&&ki!==n&&CUR.bnames[k]){ nn[shift(ki)]=CUR.bnames[k]; } } CUR.bnames=nn;
     CUR.maxBill=Math.max(0,(CUR.maxBill||0)-1);
     CUR.bill=(CUR.bill===n)?Math.max(0,n-1):shift(CUR.bill); if(CUR.bill>CUR.maxBill)CUR.bill=CUR.maxBill; if(CUR.bill<0)CUR.bill=0;
     CUR.sel=null; CUR.billOk=false; saveDraft(); persistBillMeta();
   };
   if(mode==='del'){ (CUR.pending||[]).forEach(function(l){ if((Number(l.BillNumber)||0)===n)l._delx=true; }); }
   var saved=savedLines(); var changed=[];
   saved.forEach(function(s){ if(s.extraOf_ID)return; var ob=Number(s.billNumber)||0;
     if(ob===n){ if(mode==='xfer'){ var ln=mkModified(s,Number(s.price)||0,(s.comments||null)); ln.BillNumber=tgt; changed.push(ln); }
       else { var l0=mkModified(s,Number(s.price)||0,(s.comments||null)); l0.BillNumber=0; changed.push(l0); var neg=mkLineFromSaved(s,-(Number(s.quantity)||0)); neg.BillNumber=0; CUR.pending.push(neg); } }
     else { var nb=shift(ob); if(nb!==ob){ var l2=mkModified(s,Number(s.price)||0,(s.comments||null)); l2.BillNumber=nb; changed.push(l2); } } });
   if(changed.length){ var ord=CUR.order; var order={Order_ID:ord.order_ID,TradingPeriod_ID:-1,Employee_ID:0,ServiceArea_ID:ord.serviceArea_ID,Table_ID:CUR.id,Guests:0,PriceList_ID:PL.defaultPriceList,Customer_ID:null,CustomerName:null,CustomerDiscount:null,TimeOpen:null,TimeBilled:null,TimePayed:null,Comments:null,LastChanged:null,ExternalId:null,OrderProducts:changed,OrdersOrder:[],TrackingState:0,EntityIdentifier:'00000000-0000-0000-0000-000000000000'};
     flash(L.saving);
     fetch('/api/save?pricelistId='+PL.defaultPriceList,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify([order])})
       .then(function(rr){ if(!rr.ok) throw new Error('save '+rr.status); return rr.text(); })
       .then(function(){ return fetch('/api/order?table='+CUR.id).then(function(x){return x.json();}); })
       .then(function(o){ CUR.order=o; applyLocal(); CUR._osig=orderSig(o); renderPlates(o); })
       .catch(function(e){ alertDlg(L.error+': '+e); renderPlates(CUR.order); });
   } else { applyLocal(); renderPlates(CUR.order); } }
 function activeList(){ return PL.priceLists.filter(function(p){return p.priceList_ID===PL.defaultPriceList;})[0]; }
 function menuCategories(){
   if(!PL){ fetch('/api/pricelist').then(function(r){return r.json();}).then(function(pl){PL=pl;menuCategories();}).catch(function(){ flash(L.error); document.getElementById('menu').innerHTML='<div id="pempty">'+L.error+'</div>'; }); return; }
   var cats=activeList().priceListItems.filter(function(i){return i.type===0;}).sort(function(a,b){return a.sort-b.sort;});
   var noteTile='<div class="cat notecat" onclick="openNote()">'+esc(L.noteCat)+'</div>';
   document.getElementById('menu').innerHTML='<div class="mgrid">'+noteTile+cats.map(function(c){return '<div class="cat" onclick="openCat('+c.priceListItem_ID+')">'+esc(c.description)+'</div>';}).join('')+'</div>';
 }
 function openCat(catId){
   var prods=activeList().priceListItems.filter(function(i){return i.type===2&&i.parent_ID===catId;}).sort(function(a,b){return a.sort-b.sort;});
   document.getElementById('menu').innerHTML='<div class="mgrid"><div class="prod back" onclick="menuCategories()">&#8230;</div>'+prods.map(function(pr){return '<div class="prod" onclick="tapProduct('+pr.priceListItem_ID+')">'+esc(pr.descriptionShort||pr.description)+'</div>';}).join('')+'</div>';
 }
 function norm(s){ s=(s==null?'':s.toString()).toLowerCase(); if(s.normalize){ s=s.normalize('NFD').replace(/[\u0300-\u036f]/g,''); } return s.replace(/\u03c2/g,'\u03c3'); }
 function lev(a,b){ var m=a.length,n=b.length,i,j; if(!m)return n; if(!n)return m; var d=[]; for(i=0;i<=m;i++)d[i]=[i]; for(j=0;j<=n;j++)d[0][j]=j; for(i=1;i<=m;i++){ for(j=1;j<=n;j++){ var c=a.charAt(i-1)===b.charAt(j-1)?0:1; d[i][j]=Math.min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+c); } } return d[m][n]; }
 function subseq(q,s){ var i=0,j=0,first=-1,last=-1; while(i<q.length&&j<s.length){ if(q.charAt(i)===s.charAt(j)){ if(first<0)first=j; last=j; i++; } j++; } return i===q.length?(last-first):-1; }
 function fuzzyScore(q,s){ if(!q)return 0; var idx=s.indexOf(q); if(idx>=0)return 10000-idx*5-(s.length-q.length); var gap=subseq(q,s); if(gap>=0)return 5000-gap*3-(s.length-q.length); var ql=q.length; var best=lev(q,s); var words=s.split(/[^a-z0-9\u0370-\u03ff]+/); words.forEach(function(w){ if(w){ if(w.indexOf(q)>=0)best=0; var dd=lev(q,w); if(dd<best)best=dd; } }); var tol=ql<=4?1:(ql<=7?2:3); if(best<=tol)return 2000-best*100-s.length; return -1; }
 function onSearch(){ var q=norm(document.getElementById('psearch').value.trim()); if(!q){ menuCategories(); return; } if(!PL)return; var prods=activeList().priceListItems.filter(function(i){return i.type===2;}); var scored=[]; prods.forEach(function(pr){ var sc=Math.max(fuzzyScore(q,norm(pr.descriptionShort||pr.description)),fuzzyScore(q,norm(pr.description))); if(sc>=0)scored.push({pr:pr,sc:sc}); }); scored.sort(function(a,b){return b.sc-a.sc;}); var top=scored.slice(0,30); var mn=document.getElementById('menu'); if(!top.length){ mn.innerHTML='<div id="pempty">'+esc(L.empty)+'</div>'; return; } mn.innerHTML='<div class="mgrid">'+top.map(function(o){return '<div class="prod" onclick="tapProduct('+o.pr.priceListItem_ID+')">'+esc(o.pr.descriptionShort||o.pr.description)+'</div>';}).join('')+'</div>'; }
 function tapProduct(id){
   var it=activeList().priceListItems.filter(function(i){return i.priceListItem_ID===id;})[0]; if(!it)return;
   // quick add: drop the item in immediately at qty 1 / menu price on the active level+bill, and select it so the
   // edit / +/- / move buttons are one tap away. Repeat taps of the same plain item stack onto the one line.
   var price=Number(it.price)||0, pid=it.priceListItem_ID, lv=(CUR.level||1), bl=(CUR.bill||0);
   var ex=(CUR.pending||[]).filter(function(l){ return !l._edit&&l.Product_ID===pid&&Number(l.Price)===price&&(Number(l.CourseSeq)||1)===lv&&(Number(l.BillNumber)||0)===bl&&!l.Comments&&(Number(l.Quantity)||0)>0; })[0];
   var sid;
   if(ex){ ex.Quantity=(Number(ex.Quantity)||0)+1; recalc(ex); sid=ex._id; }
   else { var ln=mkLine(it,1,price,null); CUR.pending.push(ln); sid=ln._id; }
   CUR.sel={kind:'p',ref:sid}; saveDraft(); renderPlates(CUR.order);
 }
 function qadj(d){ if(!window.ADD)return; window.ADD.qty=Math.max(1,window.ADD.qty+d); document.getElementById('sh_qty').textContent=window.ADD.qty; }
 function closeSheet(){ document.getElementById('sheet').style.display='none'; }
 function doAdd(){
   if(!window.ADD)return; var it=window.ADD.item, qty=window.ADD.qty;
   var price=parseFloat((document.getElementById('sh_price').value||'').replace(',','.')); if(isNaN(price))price=Number(it.price)||0;
   var cmt=document.getElementById('sh_cmt').value.trim()||null;
   CUR.pending.push(mkLine(it,qty,price,cmt)); saveDraft(); closeSheet(); renderPlates(CUR.order);
 }
 function selectRow(kind,ref){ if(CUR.sel&&CUR.sel.kind===kind&&CUR.sel.ref===ref){ CUR.sel=null; } else { CUR.sel={kind:kind,ref:ref}; CUR.level=selLevel(); } renderPlates(CUR.order); }
 function savedLines(){ return (CUR.order&&CUR.order.orderProducts)?CUR.order.orderProducts:[]; }
 function findPending(id){ return (CUR.pending||[]).filter(function(l){return l._id===id;})[0]; }
 function removePending(id){ CUR.pending=(CUR.pending||[]).filter(function(l){return l._id!==id;}); if(CUR.sel&&CUR.sel.kind==='p'&&CUR.sel.ref===id)CUR.sel=null; }
 function findEdit(oid){ var a=CUR.pending||[]; for(var i=0;i<a.length;i++){ if(a[i]&&a[i]._edit&&a[i].OrderLine_ID===oid)return a[i]; } return null; }
 function recalc(l){ l.Value=Math.round((Number(l.Price)||0)*(Number(l.Quantity)||0)*100)/100; }
 function effQty(pid){ var q=0; savedLines().forEach(function(l){ if(l.product_ID===pid)q+=Number(l.quantity)||0; }); (CUR.pending||[]).forEach(function(l){ if(l.Product_ID===pid&&!l._edit)q+=Number(l.Quantity)||0; }); return q; }
 function selRow(){ if(!CUR.sel)return null; if(CUR.sel.kind==='note'){ var nn=(CUR.notes&&CUR.notes[CUR.sel.ref]!=null)?CUR.notes[CUR.sel.ref]:null; return (nn!=null)?{k:'note',i:CUR.sel.ref,t:(nn&&nn.t!=null?nn.t:'')}:null; } if(CUR.sel.kind==='p'){ var l=findPending(CUR.sel.ref); return l?{k:'p',l:l}:null; } var s=savedLines().filter(function(x){return x.orderLine_ID===CUR.sel.ref;})[0]; return s?{k:'c',l:s}:null; }
 function mkLine(it,qty,price,cmt){ var taxId=it.taxes_ID; var tax=(PL.taxes.filter(function(t){return t.taxes_ID===taxId;})[0]||{}).perCent||13; var value=Math.round(price*qty*100)/100; return {CourseSeq:(CUR.level||1),Product_ID:it.priceListItem_ID,Description:it.description,Quantity:qty,Price:price,TaxPrcnt:tax,TaxFixed:0,ExtraOf_ID:null,TimeOrdered:null,TimePrinted:null,TimeToServe:null,TimeServed:null,TimeBilled:null,LastChanged:null,Tax_ID:taxId,DisCount:0,Value:value,KotPercent:0,OrdersOrder_ID:0,BillNumber:(CUR.bill||0),TimePayed:null,Employee_ID:0,DiscountPoints:null,Comments:cmt||null,Original_ReceiptItems_ID:null,Source_ID:null,ErrorOnChanged:null,ExtraAction:null,TrackingState:2,EntityIdentifier:'00000000-0000-0000-0000-000000000000',_id:++CUR.seq,_ts:Date.now()}; }
 function mkLineFromSaved(s,qty){ var price=Number(s.price)||0; var value=Math.round(price*qty*100)/100; return {CourseSeq:s.courseSeq||1,Product_ID:s.product_ID,Description:s.description,Quantity:qty,Price:price,TaxPrcnt:(s.taxPrcnt!=null?s.taxPrcnt:13),TaxFixed:0,ExtraOf_ID:null,TimeOrdered:null,TimePrinted:null,TimeToServe:null,TimeServed:null,TimeBilled:null,LastChanged:null,Tax_ID:(s.tax_ID!=null?s.tax_ID:null),DisCount:0,Value:value,KotPercent:0,OrdersOrder_ID:0,BillNumber:(s.billNumber||0),TimePayed:null,Employee_ID:0,DiscountPoints:null,Comments:null,Original_ReceiptItems_ID:null,Source_ID:null,ErrorOnChanged:null,ExtraAction:null,TrackingState:2,EntityIdentifier:'00000000-0000-0000-0000-000000000000',_id:++CUR.seq,_ts:Date.now()}; }
 function qInc(){ var r=selRow(); if(!r){ flash(L.selectItem); return; } if(r.k==='p'){ r.l.Quantity=(Number(r.l.Quantity)||0)+1; if(r.l.Quantity===0){ removePending(r.l._id); } else { recalc(r.l); } } else { var pid=r.l.product_ID, price=Number(r.l.price)||0; var neg=(CUR.pending||[]).filter(function(l){return !l._edit&&l.Product_ID===pid&&(Number(l.Quantity)||0)<0;})[0]; if(neg){ neg.Quantity=(Number(neg.Quantity)||0)+1; if(neg.Quantity===0){ removePending(neg._id); } else { recalc(neg); } } else { var pos=(CUR.pending||[]).filter(function(l){return !l._edit&&l.Product_ID===pid&&(Number(l.Quantity)||0)>0&&Number(l.Price)===price;})[0]; if(pos){ pos.Quantity=(Number(pos.Quantity)||0)+1; recalc(pos); } else { CUR.pending.push(mkLineFromSaved(r.l,1)); } } } saveDraft(); renderPlates(CUR.order); }
 function qDec(){ var r=selRow(); if(!r){ flash(L.selectItem); return; } var pid=(r.k==='p')?r.l.Product_ID:r.l.product_ID; if(effQty(pid)<1){ flash(L.cantRemove); return; } if(r.k==='p'){ r.l.Quantity=(Number(r.l.Quantity)||0)-1; if(r.l.Quantity===0){ removePending(r.l._id); } else { recalc(r.l); } } else { var price=Number(r.l.price)||0; var pos=(CUR.pending||[]).filter(function(l){return !l._edit&&l.Product_ID===pid&&(Number(l.Quantity)||0)>0&&Number(l.Price)===price;})[0]; if(pos){ pos.Quantity=(Number(pos.Quantity)||0)-1; if(pos.Quantity===0){ removePending(pos._id); } else { recalc(pos); } } else { var neg=(CUR.pending||[]).filter(function(l){return !l._edit&&l.Product_ID===pid&&(Number(l.Quantity)||0)<0;})[0]; if(neg){ neg.Quantity=(Number(neg.Quantity)||0)-1; recalc(neg); } else { CUR.pending.push(mkLineFromSaved(r.l,-1)); } } } saveDraft(); renderPlates(CUR.order); }
 function mkModified(s,price,cmt){ var qty=Number(s.quantity)||0; var value=Math.round(price*qty*100)/100; return {Order_ID:s.order_ID,OrderLine_ID:s.orderLine_ID,CourseSeq:s.courseSeq,Product_ID:s.product_ID,Description:s.description,Quantity:qty,Price:price,TaxPrcnt:s.taxPrcnt,TaxFixed:s.taxFixed,ExtraOf_ID:s.extraOf_ID,TimeOrdered:s.timeOrdered,TimePrinted:s.timePrinted,TimeToServe:s.timeToServe,TimeServed:s.timeServed,TimeBilled:s.timeBilled,LastChanged:s.lastChanged,Tax_ID:s.tax_ID,DisCount:s.disCount,Value:value,KotPercent:s.kotPercent,OrdersOrder_ID:s.ordersOrder_ID,BillNumber:s.billNumber,TimePayed:s.timePayed,Employee_ID:s.employee_ID,DiscountPoints:s.discountPoints,Comments:cmt,Original_ReceiptItems_ID:s.original_ReceiptItems_ID,Source_ID:s.source_ID,ErrorOnChanged:s.errorOnChanged,ExtraAction:s.extraAction,TrackingState:1,EntityIdentifier:s.entityIdentifier||'00000000-0000-0000-0000-000000000000'}; }
 function openNote(idx){ window.NOTEIDX=(idx==null?-1:idx); document.getElementById('nsh_title').textContent=L.noteCat; document.getElementById('nsh_text').value=(idx!=null&&CUR&&CUR.notes&&CUR.notes[idx]!=null)?(CUR.notes[idx].t||''):''; document.getElementById('nsheet').style.display='flex'; setTimeout(function(){ try{document.getElementById('nsh_text').focus();}catch(e){} },60); }
 function closeNote(){ document.getElementById('nsheet').style.display='none'; }
 function parseNotes(nr){ var out=[]; if(nr){ var s=(''+nr).trim(); if(s){ var arr=null; if(s.charAt(0)==='['){ try{ var p=JSON.parse(s); if(Array.isArray(p)){ var valid=true; for(var i=0;i<p.length;i++){ var e=p[i]; if(!(typeof e==='string'||(e&&typeof e==='object'&&e.t!=null))){ valid=false; break; } } if(valid)arr=p; } }catch(e){} } if(arr){ for(var j=0;j<arr.length;j++){ var it=arr[j]; if(typeof it==='string'){ if(it.trim())out.push({t:it,ts:0,ok:false,seq:1,bill:0}); } else { var tx=''+it.t; if(tx.trim())out.push({t:tx,ts:Number(it.ts)||0,ok:(it.ok===true),seq:(Number(it.seq)||1),bill:(Number(it.bill)||0)}); } } } else { out=[{t:s,ts:0,ok:false,seq:1,bill:0}]; } } } return out; }
 function saveNotes(){ var C=CUR; C._nraw=(C.notes&&C.notes.length)?JSON.stringify(C.notes):''; C._nsaving=(C._nsaving||0)+1; var done=function(){ C._nsaving=Math.max(0,(C._nsaving||1)-1); }; fetch('/api/note?table='+C.id,{method:'POST',headers:{'Content-Type':'text/plain; charset=utf-8'},body:C._nraw}).then(done,done); }
 function draftSig(arr){ if(!arr||!arr.length)return ''; var a=[]; for(var i=0;i<arr.length;i++){ var l=arr[i]; var ks=[]; for(var k in l){ if(k.charAt(0)!=='_')ks.push(k); } ks.sort(); var p=[]; for(var j=0;j<ks.length;j++){ p.push(ks[j]+'='+l[ks[j]]); } a.push(p.join(',')); } a.sort(); return a.join('~'); }
 function saveDraft(){ if(!CUR)return; var C=CUR; var arr=C.pending||[]; var body=arr.length?JSON.stringify(arr):'[]'; C._draw=draftSig(arr); C._dsaving=(C._dsaving||0)+1; var done=function(){ C._dsaving=Math.max(0,(C._dsaving||1)-1); }; fetch('/api/draft?table='+C.id,{method:'POST',headers:{'Content-Type':'application/json'},body:body}).then(done,done); }
 function adoptDraft(arr){ CUR.pending=Array.isArray(arr)?arr:[]; CUR.pending.forEach(function(l,i){ l._id=++CUR.seq; if(!l._ts)l._ts=Date.now()+i; }); }
 function saveNote(){ var v=document.getElementById('nsh_text').value; var t=(v&&v.trim())?v:''; if(!CUR.notes)CUR.notes=[]; var idx=window.NOTEIDX; var selIdx=-1; if(idx==null||idx<0){ if(t){ CUR.notes.push({t:t,ts:Date.now(),ok:false,seq:(CUR.level||1),bill:(CUR.bill||0)}); selIdx=CUR.notes.length-1; } } else { if(t){ if(CUR.notes[idx]&&typeof CUR.notes[idx]==='object'){ CUR.notes[idx].t=t; if(!CUR.notes[idx].ts)CUR.notes[idx].ts=Date.now(); if(!CUR.notes[idx].seq)CUR.notes[idx].seq=(CUR.level||1); if(CUR.notes[idx].bill==null)CUR.notes[idx].bill=(CUR.bill||0); } else CUR.notes[idx]={t:t,ts:Date.now(),ok:false,seq:(CUR.level||1),bill:(CUR.bill||0)}; selIdx=idx; } else CUR.notes.splice(idx,1); } CUR.sel=(selIdx>=0)?{kind:'note',ref:selIdx}:null; closeNote(); saveNotes(); renderPlates(CUR.order); }
 function removeNote(){ var r=selRow(); if(!r||r.k!=='note'){ return; } var ix=r.i; confirmDlg(L.noteDelConfirm, function(){ if(CUR.notes)CUR.notes.splice(ix,1); CUR.sel=null; saveNotes(); renderPlates(CUR.order); }); }
 function aiFill(){ if(window.AIBUSY)return; var r=selRow(); var note=(r&&r.k==='note'&&r.t!=null)?(''+r.t):''; if(!note||!note.trim()){ flash(L.selectItem); return; } if(!PL){ flash(L.aiErr); return; }
   var tid=CUR.id; var noteBill=(r&&r.k==='note'&&CUR.notes&&CUR.notes[r.i])?(Number(CUR.notes[r.i].bill)||0):(CUR.bill||0);
   var btn=document.getElementById('qai'); window.AIBUSY=true; if(btn){ btn.classList.add('busy'); btn._t=btn.textContent; btn.textContent=String.fromCharCode(8230); } flash(L.aiThinking);
   var ac=('AbortController' in window)?new AbortController():null; var to=setTimeout(function(){ if(ac)ac.abort(); },30000);
   fetch('/api/aifill?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({note:note,level:(CUR.level||1),lnames:(CUR.lnames||{})}),signal:ac?ac.signal:undefined})
     .then(function(r){ if(!r.ok) throw new Error('ai '+r.status); return r.json(); })
     .then(function(res){ if(!CUR||CUR.id!==tid)return; if(res&&res.error){ flash(res.error==='nokey'?L.aiNoKey:L.aiErr); return; } if(!PL)return; var items=(res&&res.items)?res.items:[]; if(items.length>40)items=items.slice(0,40); var added=0; items.forEach(function(o){ var id=parseInt(o.product_id,10); if(!id)return; var it=activeList().priceListItems.filter(function(i){return i.priceListItem_ID===id;})[0]; if(!it)return; var q=parseInt(o.quantity,10); if(!q||q<1)q=1; if(q>99)q=99; var pr=(o.price!=null&&!isNaN(Number(o.price))&&Number(o.price)>0)?Number(o.price):(Number(it.price)||0); var cm=(o.comment!=null&&(''+o.comment).trim())?(''+o.comment).trim():null; var sq=parseInt(o.seq,10); if(!sq||sq<1)sq=(CUR.level||1); var ln=mkLine(it,q,pr,cm); ln.CourseSeq=sq; ln.BillNumber=noteBill; CUR.pending.push(ln); added++; }); if(!CUR.lnames)CUR.lnames={}; if(added){ var grps=(res&&res.groups)?res.groups:[]; var capL=Math.max(usedMaxLevel(),CUR.maxLevel||1); var nch=false; grps.forEach(function(g){ var gs=parseInt(g.seq,10); var gn=(g.name!=null)?(''+g.name).trim():''; if(gs&&gs>=1&&gs<=capL&&gn&&!CUR.lnames[gs]){ CUR.lnames[gs]=gn; nch=true; } }); if(nch)persistSeqNames(); } if(added){ CUR.sel=null; saveDraft(); } renderPlates(CUR.order); flash(added?(L.aiAdded+' '+added):(items.length?L.aiErr:L.aiNone)); })
     .catch(function(){ flash(L.aiErr); })
     .then(function(){ clearTimeout(to); window.AIBUSY=false; if(btn){ btn.classList.remove('busy'); if(btn._t!=null){ btn.textContent=btn._t; } } });
 }
 function openEdit(){ var r=selRow(); if(!r){ flash(L.selectItem); return; } if(r.k==='note'){ openNote(r.i); return; } window.EDIT=r; var l=r.l; var ed=(r.k==='c')?findEdit(l.orderLine_ID):null; var pv=ed?ed.Price:((r.k==='p')?l.Price:l.price); var cv=ed?ed.Comments:((r.k==='p')?l.Comments:l.comments); document.getElementById('esh_name').textContent=(r.k==='p')?l.Description:l.description; document.getElementById('esh_price').value=(Number(pv)||0).toFixed(2); document.getElementById('esh_cmt').value=(cv||''); document.getElementById('esheet').style.display='flex'; }
 function closeEdit(){ document.getElementById('esheet').style.display='none'; }
 function doEdit(){ var r=window.EDIT; if(!r){ closeEdit(); return; }
   var base=(r.k==='p')?r.l.Price:r.l.price;
   var price=parseFloat((document.getElementById('esh_price').value||'').replace(',','.')); if(isNaN(price))price=Number(base)||0;
   var cmt=document.getElementById('esh_cmt').value.trim()||null;
   if(r.k==='p'){ r.l.Price=price; r.l.Comments=cmt; recalc(r.l); closeEdit(); saveDraft(); renderPlates(CUR.order); return; }
   // committed line: stage the price/comment change as a DRAFT edit (no server write until OK; cancel reverts).
   var s=r.l; var oid=s.orderLine_ID; var qy=Number(s.quantity)||0;
   var unchanged=(Math.round((Number(price)||0)*100)===Math.round((Number(s.price)||0)*100))&&((cmt||null)===(s.comments||null));
   var existing=findEdit(oid);
   if(unchanged){ if(existing)removePending(existing._id); CUR.sel={kind:'c',ref:oid}; closeEdit(); saveDraft(); renderPlates(CUR.order); return; }
   if(existing){ existing.Price=price; existing.Comments=cmt; existing.Value=Math.round(price*qy*100)/100; }
   else { var el=mkModified(s,price,cmt); el._edit=true; el._id=++CUR.seq; el._ts=Date.now(); CUR.pending.push(el); }
   CUR.sel={kind:'c',ref:oid}; closeEdit(); saveDraft(); renderPlates(CUR.order);
 }
 function commit(){
   var markOk=function(){ if(CUR&&CUR.notes&&CUR.notes.length){ var nch=false; for(var ni=0;ni<CUR.notes.length;ni++){ if(CUR.notes[ni]&&!CUR.notes[ni].ok){ CUR.notes[ni].ok=true; nch=true; } } if(nch)saveNotes(); } if(CUR&&(CUR.maxLevel||1)>1&&!CUR.seqOk){ CUR.seqOk=true; persistSeqNames(); } if(CUR&&(CUR.maxBill||0)>=1&&!CUR.billOk){ CUR.billOk=true; persistBillMeta(); } };
   var refresh=function(){ return fetch('/api/order?table='+CUR.id).then(function(r){return r.json();}).catch(function(){return CUR?CUR.order:null;}).then(function(o){ if(!CUR)return true; CUR.order=o; CUR._osig=orderSig(o); CUR._extChanged=false; CUR._draftCoEdited=false; CUR.sel=null; renderPlates(o); return true; }); };
   // Atomically CLAIM the shared draft (single-threaded server => exactly one device receives a given draft's
   // items). The claimer commits them; a racing second device claims [] and commits nothing -> no duplicate lines.
   return fetch('/api/draftclaim?table='+CUR.id,{method:'POST'}).then(function(r){return r.json();}).catch(function(){ return (CUR&&CUR.pending)?CUR.pending:[]; })
     .then(function(claimed){
       if(!CUR)return true;
       var items=Array.isArray(claimed)?claimed:[];
       CUR.pending=[]; CUR._draw=draftSig([]);
       if(!items.length){ markOk(); return refresh(); }
       var ord=CUR.order, hasOrder=ord&&ord.order_ID;
       var orderId=hasOrder?ord.order_ID:2000000001;
       var savedById={}; ((ord&&ord.orderProducts)?ord.orderProducts:[]).forEach(function(s){ savedById[s.orderLine_ID]=s; });
       var lines=items.map(function(pl,i){ if(pl._edit){ var cur=savedById[pl.OrderLine_ID]; if(!cur)return null; var re=mkModified(cur,Number(pl.Price)||0,(pl.Comments!=null?pl.Comments:null)); re.Order_ID=orderId; return re; } var l={}; for(var k in pl){ if(k.charAt(0)!=='_')l[k]=pl[k]; } l.Order_ID=orderId; l.OrderLine_ID=2000000001+i; return l; }).filter(function(x){return x;});
       if(!lines.length){ markOk(); return refresh(); }
       var order={Order_ID:orderId,TradingPeriod_ID:-1,Employee_ID:0,ServiceArea_ID:(hasOrder?ord.serviceArea_ID:CUR.areaId),Table_ID:CUR.id,Guests:0,PriceList_ID:PL.defaultPriceList,Customer_ID:null,CustomerName:null,CustomerDiscount:null,TimeOpen:null,TimeBilled:null,TimePayed:null,Comments:null,LastChanged:null,ExternalId:null,OrderProducts:lines,OrdersOrder:[],TrackingState:(hasOrder?0:2),EntityIdentifier:'00000000-0000-0000-0000-000000000000'};
       document.getElementById('htitle').textContent=L.saving;
       return fetch('/api/save?pricelistId='+PL.defaultPriceList,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify([order])})
         .then(function(r){ if(!r.ok) throw new Error('save '+r.status); return r.text(); })
         .then(function(){ markOk(); return refresh(); })
         .catch(function(e){ if(CUR){ adoptDraft(items); CUR._draw=draftSig(CUR.pending); saveDraft(); renderPlates(CUR.order); } throw e; });
     });
 }
 function emptyTbl(){ var s=(CUR&&CUR.order&&CUR.order.orderProducts)?CUR.order.orderProducts.length:0; var p=(CUR&&CUR.pending)?CUR.pending.length:0; return (s+p)===0; }
 function doPrint(){ var bill=(((CUR&&CUR.maxBill)||0)>0)?(CUR.bill||0):-1; printBill(bill); }
 function doPrintAll(){ printBill(-1); }
 function printBill(bill){ toggleMenu();
   withFreshOrder(function(){
     if(emptyTbl()){ flash(L.empty); return; }
     commit()
       .then(function(){ return fetch('/api/print?table='+CUR.id+'&bill='+bill,{method:'POST'}); })
       .then(function(r){ if(r&&r.ok){ flash(L.printed); } else { flash(L.error); } })
       .catch(function(e){ alertDlg(L.error+': '+e); if(CUR)renderPlates(CUR.order); });
   });
 }
 function doClose(){ toggleMenu(); var preOrder=CUR&&CUR.order&&CUR.order.orderProducts&&CUR.order.orderProducts.length>0; var prePend=CUR&&CUR.pending&&CUR.pending.length>0; var hasNotes=CUR&&CUR.notes&&CUR.notes.length>0; var hasSeq=CUR&&(CUR.maxLevel||1)>1; var hasBill=CUR&&(CUR.maxBill||0)>=1; if(!preOrder&&!prePend&&!hasNotes&&!hasSeq&&!hasBill){ flash(L.empty); return; } confirmDlg(L.closeConfirm, function(){ withFreshOrder(function(){
   var tid=CUR.id;
   // Closing DISCARDS any un-committed draft (it must NOT print to the kitchen) and wipes local show-state.
   fetch('/api/draft?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:'[]'}).catch(function(){});
   CUR.pending=[]; CUR._draw=draftSig([]); CUR.sel=null; CUR.notes=[]; CUR._nraw=''; CUR.lnames={}; CUR.maxLevel=1; CUR.seqOk=false; CUR.bnames={}; CUR.maxBill=0; CUR.billOk=false; CUR.bill=0;
   var clearShow=function(){ fetch('/api/draft?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:'[]'}).catch(function(){}); fetch('/api/note?table='+tid,{method:'POST',headers:{'Content-Type':'text/plain'},body:''}).catch(function(){}); fetch('/api/seqnames?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).catch(function(){}); fetch('/api/billmeta?table='+tid,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).catch(function(){}); showTables(); };
   var hasOrder=CUR&&CUR.order&&CUR.order.orderProducts&&CUR.order.orderProducts.length>0;
   if(!hasOrder){ clearShow(); return; }   // nothing committed in the POS -> just drop the draft and free the table
   var saved=(CUR.order&&CUR.order.orderProducts)?CUR.order.orderProducts:[]; var tot=0; saved.forEach(function(l){ tot+=Number(l.value)||0; }); var billed=!!(CUR.order&&CUR.order.timeBilled);
   var resFail=function(t){ var res; try{ res=JSON.parse(t); }catch(e){ res=null; } return res===false||(res&&(res.result===false||res.Result===false)); };
   var voidIt=function(){ return fetch('/api/cancel?table='+tid,{method:'POST'}).then(function(r){ if(r&&r.ok){ return r.text().then(function(t){ if(resFail(t)){ alertDlg(L.closeFailed); } else { clearShow(); } }); } return r.text().then(function(t){ alertDlg(L.error+': '+t); }); }); };
   if(tot<=0){ voidIt(); return; }
   var rcpt=billed?'false':'true';   // billed orders are already receipted -> skip re-billing, just pay+close
   fetch('/api/close?table='+tid+'&receipt='+rcpt,{method:'POST'}).then(function(r){ if(!r||!r.ok){ return billed?alertDlg(L.closeFailed):voidIt(); } return r.text().then(function(t){ if(resFail(t)){ return billed?alertDlg(L.closeFailed):voidIt(); } clearShow(); }); }).catch(function(){ flash(L.error); });
 }); }); }
 function doMove(){ toggleMenu(); if(!CUR||!CUR.order||!CUR.order.order_ID){ flash(L.empty); return; }
   document.getElementById('movetitle').textContent=L.moveTo;
   document.getElementById('movegrid').innerHTML='<div id="pempty">...</div>';
   document.getElementById('moveov').style.display='flex';
   Promise.all([
     fetch('/api/tables').then(function(r){return r.json();}),
     fetch('/api/drafts').then(function(r){return r.json();}).catch(function(){return [];})
   ]).then(function(res){
     var tables=Array.isArray(res[0])?res[0]:[]; var dr=res[1]||{}; var dl=Array.isArray(dr)?dr:(Array.isArray(dr.d)?dr.d:[]); var ol=(dr&&Array.isArray(dr.o))?dr.o:[]; var dset={}; dl.forEach(function(id){dset[id]=true;}); ol.forEach(function(id){dset[id]=true;});
     var empty=tables.filter(function(t){ return t.table_ID!==CUR.id && !t.order_ID && !dset[t.table_ID]; });
     empty.sort(function(a,b){var na=parseInt(a.description,10),nb=parseInt(b.description,10);if(isNaN(na))na=1e9;if(isNaN(nb))nb=1e9;return na-nb||(a.description||'').localeCompare(b.description||'');});
     var g=document.getElementById('movegrid');
     if(!empty.length){ g.innerHTML='<div id="pempty">'+esc(L.empty)+'</div>'; return; }
     g.innerHTML=empty.map(function(t){ return '<div class="tile" style="background:'+esc(safeColor(t.colorHex))+'" onclick="pickMove('+t.table_ID+')">'+esc(t.description)+'</div>'; }).join('');
   }).catch(function(){ document.getElementById('movegrid').innerHTML='<div id="pempty">'+esc(L.error)+'</div>'; });
 }
 function closeMove(){ document.getElementById('moveov').style.display='none'; }
 function openSettings(){ document.getElementById('amenu').style.display='none'; var t=document.getElementById('set_rules'); t.value=''; document.getElementById('setov').style.display='flex'; fetch('/api/rules').then(function(r){return r.text();}).then(function(x){ t.value=x||''; }).catch(function(){ flash(L.error); }); }
 function closeSettings(){ document.getElementById('setov').style.display='none'; }
 function saveRules(){ var t=document.getElementById('set_rules'); fetch('/api/rules',{method:'POST',headers:{'Content-Type':'text/plain; charset=utf-8'},body:t.value}).then(function(r){ if(r&&r.ok){ flash(L.rulesSaved); closeSettings(); } else { flash(L.error); } }).catch(function(){ flash(L.error); }); }
 function pickMove(target){
   var sd=(CUR.pending&&CUR.pending.length)? fetch('/api/draft?table='+CUR.id,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(CUR.pending)}) : Promise.resolve();
   sd.then(function(){ return fetch('/api/move?from='+CUR.id+'&to='+target,{method:'POST'}); })
     .then(function(r){ if(r&&r.ok){ closeMove(); showTables(); } else { flash(L.error); } })
     .catch(function(){ flash(L.error); });
 }
 function armBack(){ try{ history.pushState(null,'',location.href); }catch(e){} }
 function applyWrapHeight(){ try{ var v=parseFloat(localStorage.getItem('estwrap')); if(v&&v>=10&&v<=85){ document.getElementById('platewrap').style.height=v+'vh'; } }catch(e){} }
 function wrapSnaps(){ var vh=window.innerHeight||document.documentElement.clientHeight; return [0.16*vh,0.38*vh,0.72*vh]; }
 function nearestSnapIdx(h){ var s=wrapSnaps(); var b=0; for(var i=1;i<s.length;i++){ if(Math.abs(s[i]-h)<Math.abs(s[b]-h))b=i; } return b; }
 function snapToIdx(i){ var s=wrapSnaps(); var vh=window.innerHeight||document.documentElement.clientHeight; var pw=document.getElementById('platewrap'); pw.style.transition='height .26s cubic-bezier(.2,.7,.2,1)'; pw.style.height=s[i]+'px'; setTimeout(function(){ pw.style.transition=''; },300); try{ localStorage.setItem('estwrap',(s[i]/vh*100).toFixed(1)); }catch(e){} }
 function resolveSnap(startH,startIdx,curH,netDrag,vel){ var snaps=wrapSnaps(); var dir=0; if(Math.abs(netDrag)>14)dir=netDrag>0?1:-1; else if(Math.abs(vel)>80)dir=vel>0?1:-1; var target=startIdx; if(dir===0){ target=nearestSnapIdx(curH); } else { var best=-1; for(var i=0;i<snaps.length;i++){ if(dir>0?(i>startIdx):(i<startIdx)){ if(best<0||Math.abs(snaps[i]-curH)<Math.abs(snaps[best]-curH))best=i; } } if(best>=0)target=best; } snapToIdx(target); }
 function initSheet(){ var grip=document.getElementById('sheetgrip'); if(!grip)return; var pw=document.getElementById('platewrap'); var st=null;
   grip.addEventListener('pointerdown', function(e){ var h=pw.getBoundingClientRect().height; st={y:e.clientY,h:h,idx:nearestSnapIdx(h),py:e.clientY,pt:e.timeStamp,vel:0,moved:0}; pw.style.transition=''; try{grip.setPointerCapture(e.pointerId);}catch(x){} e.preventDefault(); }, false);
   grip.addEventListener('pointermove', function(e){ if(!st)return; var vh=window.innerHeight||document.documentElement.clientHeight; var dy=e.clientY-st.y; if(Math.abs(dy)>st.moved)st.moved=Math.abs(dy); var nh=st.h+dy; var mn=0.12*vh,mx=0.82*vh; if(nh<mn)nh=mn; if(nh>mx)nh=mx; pw.style.height=nh+'px'; var dt=e.timeStamp-st.pt; if(dt>0)st.vel=(e.clientY-st.py)/dt*1000; st.py=e.clientY; st.pt=e.timeStamp; e.preventDefault(); }, false);
   var endf=function(e){ if(!st)return; var s2=st; st=null; var h=pw.getBoundingClientRect().height; if(s2.moved<5){ snapToIdx(s2.idx===0?1:0); return; } resolveSnap(s2.h,s2.idx,h,h-s2.h,s2.vel); };
   grip.addEventListener('pointerup',endf,false); grip.addEventListener('pointercancel',endf,false); }
 function initSheetBody(){ var pw=document.getElementById('platewrap'); var menu=document.getElementById('menu'); if(!pw||!menu)return;
   function attach(el){ if(!el)return; var ds=null;
     el.addEventListener('touchstart', function(e){ if(e.touches.length!==1){ ds=null; return; } var t=e.touches[0]; var h=pw.getBoundingClientRect().height; ds={y:t.clientY,x:t.clientX,h:h,idx:nearestSnapIdx(h),mode:0,py:t.clientY,pt:e.timeStamp,vel:0}; }, {passive:true});
     el.addEventListener('touchmove', function(e){ if(!ds||e.touches.length!==1)return; var t=e.touches[0]; var dy=t.clientY-ds.y, dx=t.clientX-ds.x;
       if(ds.mode===0){ if(Math.abs(dx)>10&&Math.abs(dx)>Math.abs(dy)){ ds=null; return; } if(Math.abs(dy)<6)return; var atFull=ds.h<=wrapSnaps()[0]+2; var atTop=menu.scrollTop<=0; if(dy>0&&atTop){ ds.mode=1; } else if(dy<0&&!atFull){ ds.mode=1; } else { ds.mode=2; } }
       if(ds.mode===1){ e.preventDefault(); var vh=window.innerHeight||document.documentElement.clientHeight; var nh=ds.h+dy; var mn=0.12*vh,mx=0.82*vh; if(nh<mn)nh=mn; if(nh>mx)nh=mx; pw.style.transition=''; pw.style.height=nh+'px'; var dt=e.timeStamp-ds.pt; if(dt>0)ds.vel=(t.clientY-ds.py)/dt*1000; ds.py=t.clientY; ds.pt=e.timeStamp; } }, {passive:false});
     var endf=function(){ if(!ds)return; var d=ds; ds=null; if(d.mode===1){ var h=pw.getBoundingClientRect().height; resolveSnap(d.h,d.idx,h,h-d.h,d.vel); } };
     el.addEventListener('touchend',endf,false); el.addEventListener('touchcancel',endf,false);
   }
   attach(menu); attach(document.getElementById('srch')); }
 window.addEventListener('popstate', function(){
   if(document.getElementById('dlg').style.display==='flex'){ document.getElementById('dlg').style.display='none'; armBack(); return; }
   if(document.getElementById('sheet').style.display==='flex'){ closeSheet(); armBack(); return; }
   if(document.getElementById('esheet').style.display==='flex'){ closeEdit(); armBack(); return; }
   if(document.getElementById('nsheet').style.display==='flex'){ closeNote(); armBack(); return; }
   if(document.getElementById('lnsheet').style.display==='flex'){ closeSeqName(); armBack(); return; }
   if(document.getElementById('moveov').style.display==='flex'){ closeMove(); armBack(); return; }
   if(document.getElementById('setov').style.display==='flex'){ closeSettings(); armBack(); return; }
   if(document.getElementById('amenu').style.display==='block'){ document.getElementById('amenu').style.display='none'; armBack(); return; }
   if(VIEW==='table'){ armBack(); goBack(); return; }
   armBack();
 });
 function fsOn(){ return document.fullscreenElement||document.webkitFullscreenElement; }
 function goFullscreen(){ if(fsOn())return; var ae=document.activeElement; if(ae&&(ae.tagName==='INPUT'||ae.tagName==='TEXTAREA'))return; if(document.getElementById('sheet').style.display==='flex'||document.getElementById('esheet').style.display==='flex')return; var el=document.documentElement; var rf=el.requestFullscreen||el.webkitRequestFullscreen; if(rf){ try{ rf.call(el); }catch(e){} } }
 function exitFs(){ try{ if(document.fullscreenElement&&document.exitFullscreen) document.exitFullscreen(); else if(document.webkitFullscreenElement&&document.webkitExitFullscreen) document.webkitExitFullscreen(); }catch(e){} }
 document.addEventListener('click', goFullscreen, false);
 /* keep fullscreen during input: interactive-widget=resizes-content (viewport meta) shrinks the page when the keyboard opens, so fields reflow above it */
 document.addEventListener('click', function(e){ var m=document.getElementById('amenu'); if(m.style.display!=='block')return; if(m.contains(e.target))return; var hr=document.getElementById('hright'); if(hr===e.target||hr.contains(e.target))return; m.style.display='none'; }, false);
 document.addEventListener('click', function(e){ if(!CUR||!CUR.sel)return; var t=e.target; if(t&&t.closest&&(t.closest('.pl')||t.closest('#qbar')||t.closest('#esheet')||t.closest('#sheet')||t.closest('#nsheet')||t.closest('#lnsheet')||t.closest('#billsheet')||t.closest('#billedit')||t.closest('#menu')||t.closest('.lvlhdr')||t.closest('.addlvl')))return; CUR.sel=null; renderPlates(CUR.order); }, false);
 document.addEventListener('keydown', function(e){ if((e.key==='Enter'||e.keyCode===13) && e.target && e.target.classList && e.target.classList.contains('oneline')){ e.preventDefault(); e.target.blur(); } }, false);
 function orderSig(o){ if(!o)return ''; var s=o.orderProducts||[]; var a=['oid:'+(o.order_ID||'')]; for(var i=0;i<s.length;i++){ var l=s[i]; a.push(l.orderLine_ID+':'+l.quantity+':'+l.value+':'+(l.lastChanged||'')+':'+(l.comments||'')+':'+(l.courseSeq||1)+':'+(l.extraOf_ID||'')+':'+(l.disCount||0)); } return a.join('|'); }
 function orderDiffMsg(pre,live){ var ps=(pre&&pre.orderProducts)?pre.orderProducts:[]; var ls=(live&&live.orderProducts)?live.orderProducts:[]; var pm={},lm={}; ps.forEach(function(l){ pm[l.orderLine_ID]=l; }); ls.forEach(function(l){ lm[l.orderLine_ID]=l; }); var add=[],rem=[]; ls.forEach(function(l){ if(!pm[l.orderLine_ID])add.push(l); }); ps.forEach(function(l){ if(!lm[l.orderLine_ID])rem.push(l); }); function nm(l){ var q=Number(l.quantity)||0; var d=l.description||l.Description||'?'; return (q&&q!==1?(fmtQ(q)+' '):'')+d; } var parts=[]; if(add.length)parts.push('+ '+add.map(nm).join(', ')); if(rem.length)parts.push('- '+rem.map(nm).join(', ')); var t=parts.join('  '); if(t.length>90)t=t.slice(0,88)+String.fromCharCode(8230); return t; }
 function pollTick(){ if(document.hidden)return; if(VIEW==='tables'){ loadTables(); return; } if(VIEW!=='table'||!CUR)return; if(window.AIBUSY)return; if(window.OKGUARD)return;
   var ids=['sheet','nsheet','lnsheet','billsheet','billedit','moveov','setov','dlg']; for(var i=0;i<ids.length;i++){ if(document.getElementById(ids[i]).style.display==='flex')return; }
   if(document.getElementById('amenu').style.display==='block')return;
   var editing=(document.getElementById('esheet').style.display==='flex');
   fetch('/api/order?table='+CUR.id).then(function(r){return r.json();}).then(function(o){
     if(VIEW!=='table'||!CUR)return;
     if(editing){ if(window.EDIT&&window.EDIT.k==='c'){ var ol=window.EDIT.l, sv=(o&&o.orderProducts)?o.orderProducts:[]; var cl=sv.filter(function(x){return x.orderLine_ID===ol.orderLine_ID;})[0]; if(!cl||String(cl.lastChanged)!==String(ol.lastChanged)){ closeEdit(); CUR.order=o; CUR._osig=orderSig(o); renderPlates(o); flash(L.editConflict); } } return; }
     var sg=orderSig(o); if(sg!==CUR._osig){ CUR._osig=sg; CUR.order=o; if(CUR.pending&&CUR.pending.length)CUR._extChanged=true; renderPlates(o); }
     fetch('/api/note?table='+CUR.id).then(function(r){return r.text();}).then(function(t){ if(VIEW==='table'&&CUR&&!CUR._nsaving){ var nt=t||''; if(nt!==CUR._nraw){ CUR._nraw=nt; CUR.notes=parseNotes(nt); if(CUR.sel&&CUR.sel.kind==='note')CUR.sel=null; renderPlates(CUR.order); } } }).catch(function(){});
     fetch('/api/draft?table='+CUR.id).then(function(r){return r.json();}).then(function(d){ if(VIEW==='table'&&CUR&&!CUR._dsaving&&!window.OKGUARD){ var arr=Array.isArray(d)?d:[]; var ds=draftSig(arr); if(ds!==CUR._draw){ CUR._draw=ds; adoptDraft(arr); CUR._draftCoEdited=true; if(CUR.sel&&CUR.sel.kind==='p')CUR.sel=null; saveDraft(); renderPlates(CUR.order); } } }).catch(function(){});
   }).catch(function(){});
 }
 document.addEventListener('visibilitychange', function(){ if(!document.hidden) pollTick(); }, false);
 applyLabels(); applyWrapHeight(); initSheet(); initSheetBody(); showTables(); armBack(); setInterval(pollTick, 5000);
</script></body></html>
'@

function Send-Response($stream,[int]$code,[string]$ctype,[string]$body){
  $bytes=[Text.Encoding]::UTF8.GetBytes([string]$body)
  $head="HTTP/1.1 $code OK`r`nContent-Type: $ctype; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
  $hb=[Text.Encoding]::ASCII.GetBytes($head); $stream.Write($hb,0,$hb.Length); $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
}
function Send-Bytes($stream,[int]$code,[string]$ctype,[byte[]]$bytes){
  $head="HTTP/1.1 $code OK`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: public, max-age=86400`r`n`r`n"
  $hb=[Text.Encoding]::ASCII.GetBytes($head); $stream.Write($hb,0,$hb.Length); $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
}

# Startup auth: try a few times, but NEVER block server startup. At boot the Estiasis API (IIS/SQL)
# may still be starting; ApiRaw/ApiPost re-login lazily on the first request, so we serve regardless.
for($i=0;$i -lt 5;$i++){ try{ Login; break }catch{ Start-Sleep -Seconds 4 } }
# Pre-warm the AI menu cache off the request path so the first /api/aifill never blocks the accept loop on a menu fetch.
try{ Get-AiMenu | Out-Null }catch{}
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('0.0.0.0'), $Port)
try { $listener.Start() } catch { Write-Host "Port $Port already in use (another instance running). Exiting."; return }
Write-Host "EstiasisWeb listening on port $Port (open http://<this-machine-LAN-ip>:$Port on a phone). Ctrl+C to stop."
if(-not $NoBrowser){ try{ Start-Process "http://localhost:$Port" }catch{} }

$script:errlog = Join-Path $base 'estiasisweb_error.log'
function LogLine([string]$s){ try{ Add-Content -Path $script:errlog -Value ('['+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')+'] '+$s) -Encoding UTF8 }catch{} }
# AI calls (Anthropic) take seconds. Offload ONLY that HTTP round-trip + the reply to a background
# runspace so the single-threaded accept loop keeps serving fast requests (table opens etc.) meanwhile.
$aiWorker = {
  param($client,$stream,$reqBytes,$hdr,$errlog)
  $ErrorActionPreference='Stop'
  function SendR($s,[int]$code,$body){ try{ $bb=[Text.Encoding]::UTF8.GetBytes([string]$body); $hh="HTTP/1.1 $code OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bb.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"; $hbb=[Text.Encoding]::ASCII.GetBytes($hh); $s.Write($hbb,0,$hbb.Length); $s.Write($bb,0,$bb.Length); $s.Flush() }catch{} }
  function LogW($m){ for($li=0;$li -lt 3;$li++){ try{ Add-Content -Path $errlog -Value ('['+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')+'] '+$m) -Encoding UTF8; break }catch{ Start-Sleep -Milliseconds 20 } } }
  try {
    $r=$null
    try {
      $resp = Invoke-WebRequest 'https://api.anthropic.com/v1/messages' -Method Post -Headers $hdr -Body $reqBytes -ContentType 'application/json' -UseBasicParsing -TimeoutSec 25
      $r = ([Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())) | ConvertFrom-Json
    } catch {
      $eb=''; if($_.ErrorDetails -and $_.ErrorDetails.Message){ $eb=[string]$_.ErrorDetails.Message } else { try{ $rs=$_.Exception.Response.GetResponseStream(); $sr=New-Object IO.StreamReader($rs); $eb=$sr.ReadToEnd() }catch{} }
      LogW ('AIFILL API '+$_.Exception.Message+' :: '+$eb)
      SendR $stream 200 ('{"error":"api","detail":'+(ConvertTo-Json ([string]$eb))+'}'); try{ $client.Close() }catch{}; return
    }
    $out='{"error":"bad"}'
    if($r.stop_reason -eq 'refusal'){ $out='{"error":"refusal"}' }
    elseif($r.stop_reason -eq 'max_tokens'){ $out='{"error":"toolong"}' }
    else {
      $txt=''
      foreach($b in $r.content){ if($b.type -eq 'text' -and $b.text){ $txt=[string]$b.text; break } }
      if(-not $txt){ $out='{"items":[]}' }
      else { try{ $o=$txt|ConvertFrom-Json; if($o){ $out=$txt } }catch{ $out='{"error":"bad"}' } }
    }
    SendR $stream 200 $out
  } catch {
    LogW ('AIFILL WORKER '+$_.Exception.Message)
    try{ SendR $stream 200 '{"error":"worker"}' }catch{}
  } finally { try{ $client.Close() }catch{} }
}
$aiISS = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$aiPool = [runspacefactory]::CreateRunspacePool(1,4,$aiISS,$Host); $aiPool.Open()
$script:aiPending = New-Object System.Collections.ArrayList
while($true){
  try { $client=$listener.AcceptTcpClient() } catch { LogLine ('ACCEPT ERR='+$_.Exception.Message); Start-Sleep -Milliseconds 200; continue }
  $stream=$null; $handedOff=$false
  try {
    $stream=$client.GetStream(); try{ $stream.ReadTimeout=8000; $stream.WriteTimeout=8000 }catch{}
    $ms=New-Object IO.MemoryStream; $b1=New-Object byte[] 1; $he=-1
    while($true){ $n=$stream.Read($b1,0,1); if($n -le 0){break}; $ms.WriteByte($b1[0]); $Ln=$ms.Length; if($Ln -ge 4){ $a=$ms.GetBuffer(); if($a[$Ln-4] -eq 13 -and $a[$Ln-3] -eq 10 -and $a[$Ln-2] -eq 13 -and $a[$Ln-1] -eq 10){ $he=$Ln; break } } }
    if($he -lt 0){ $client.Close(); continue }
    $hb=New-Object byte[] $he; [Array]::Copy($ms.GetBuffer(),0,$hb,0,$he)
    $ht=[Text.Encoding]::ASCII.GetString($hb)
    $rl=($ht -split "`r`n")[0]; $pp=$rl.Split(' '); $method=$pp[0]; $path=$pp[1]
    $clen=0; if($ht -match '(?im)^Content-Length:\s*(\d+)'){ $clen=[int]$Matches[1] }
    $bodyIn=''
    if($clen -gt 0){ $bb=New-Object byte[] $clen; $rd=0; while($rd -lt $clen){ $n=$stream.Read($bb,$rd,$clen-$rd); if($n -le 0){break}; $rd+=$n }; $bodyIn=[Text.Encoding]::UTF8.GetString($bb) }

    if($path -eq '/' -or $path -eq '/index.html'){
      Send-Response $stream 200 'text/html' ($HTML.Replace('__LABELS__', $script:labels))
    } elseif($path -eq '/manifest.json'){
      Send-Response $stream 200 'application/manifest+json' '{"name":"AlexEstiasis","short_name":"AlexEstiasis","start_url":"/","display":"fullscreen","display_override":["fullscreen","standalone"],"orientation":"portrait","background_color":"#111111","theme_color":"#222831","icons":[{"src":"/icon-192.png","sizes":"192x192","type":"image/png"},{"src":"/icon-512.png","sizes":"512x512","type":"image/png"}]}'
    } elseif($path -eq '/apple-touch-icon.png' -or $path -eq '/apple-touch-icon-precomposed.png' -or $path -eq '/favicon.ico'){
      $ip=Join-Path $base 'estiasisweb-icon-180.png'; if(Test-Path $ip){ Send-Bytes $stream 200 'image/png' ([System.IO.File]::ReadAllBytes($ip)) } else { Send-Response $stream 404 'text/plain' 'no icon' }
    } elseif($path -eq '/icon-192.png'){
      $ip=Join-Path $base 'estiasisweb-icon-192.png'; if(Test-Path $ip){ Send-Bytes $stream 200 'image/png' ([System.IO.File]::ReadAllBytes($ip)) } else { Send-Response $stream 404 'text/plain' 'no icon' }
    } elseif($path -eq '/icon-512.png'){
      $ip=Join-Path $base 'estiasisweb-icon-512.png'; if(Test-Path $ip){ Send-Bytes $stream 200 'image/png' ([System.IO.File]::ReadAllBytes($ip)) } else { Send-Response $stream 404 'text/plain' 'no icon' }
    } elseif($path -eq '/api/tables'){
      Send-Response $stream 200 'application/json' (ApiRaw 'api/Tables')
    } elseif($path -eq '/api/areas'){
      Send-Response $stream 200 'application/json' (ApiRaw 'api/ServiceAreas')
    } elseif($path -like '/api/order*'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $oc = ApiRaw "api/Orders/Table/$tid"; if([string]::IsNullOrWhiteSpace($oc)){ $oc='null' }
      Send-Response $stream 200 'application/json' $oc
    } elseif($path -eq '/api/pricelist'){
      Send-Response $stream 200 'application/json' (ApiRaw 'api/PricelistsFull')
    } elseif($path -eq '/api/drafts'){
      $ids=@(); $occ=@()
      Get-ChildItem -Path $base -Filter 'draft_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $dc=''; try{ $dc=[System.IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8) }catch{}
        if($dc -and $dc.Trim() -ne '' -and $dc.Trim() -ne '[]' -and ($_.Name -match 'draft_(\d+)\.json')){ $ids += [int]$Matches[1] }
      }
      Get-ChildItem -Path $base -Filter 'note_*.txt' -ErrorAction SilentlyContinue | ForEach-Object {
        $nc2=''; try{ $nc2=[System.IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8) }catch{}
        if($nc2 -and $nc2.Trim() -ne '' -and $nc2.Trim() -ne '[]' -and ($_.Name -match 'note_(\d+)\.txt')){
          $tidN=[int]$Matches[1]; $draftN=$false
          try{ $pp=$nc2 | ConvertFrom-Json; foreach($el in @($pp)){ if(-not ($el -and $el.ok)){ $draftN=$true; break } } }catch{ $draftN=$true }
          if($draftN){ $ids += $tidN } else { $occ += $tidN }
        }
      }
      Get-ChildItem -Path $base -Filter 'seqnames_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $sc3=''; try{ $sc3=[System.IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8) }catch{}
        if($sc3 -and ($_.Name -match 'seqnames_(\d+)\.json')){ $tidS=[int]$Matches[1]; $mx=1; $sok=$false; try{ $sj=$sc3 | ConvertFrom-Json; if($sj.max){ $mx=[int]$sj.max }; if($sj.ok){ $sok=[bool]$sj.ok } }catch{}; if($mx -gt 1){ if($sok){ $occ += $tidS } else { $ids += $tidS } } }
      }
      Get-ChildItem -Path $base -Filter 'billmeta_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $bc3=''; try{ $bc3=[System.IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8) }catch{}
        if($bc3 -and ($_.Name -match 'billmeta_(\d+)\.json')){ $tidB=[int]$Matches[1]; $bmx=0; $bok=$false; try{ $bj=$bc3 | ConvertFrom-Json; if($bj.max){ $bmx=[int]$bj.max }; if($bj.ok){ $bok=[bool]$bj.ok } }catch{}; if($bmx -ge 1){ if($bok){ $occ += $tidB } else { $ids += $tidB } } }
      }
      $ids = @($ids | Select-Object -Unique)
      $occ = @($occ | Where-Object { $ids -notcontains $_ } | Select-Object -Unique)
      Send-Response $stream 200 'application/json' ('{"d":['+($ids -join ',')+'],"o":['+($occ -join ',')+']}')
    } elseif($path -like '/api/draftclaim*'){
      # Atomic claim: read the shared draft and clear it in one (single-threaded) request, so exactly one
      # caller ever receives a given draft's items. Prevents two phones double-committing the same draft.
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $dp = Join-Path $base ("draft_$tid.json")
      $dc = if(Test-Path $dp){ [System.IO.File]::ReadAllText($dp,[Text.Encoding]::UTF8) } else { '[]' }
      if([string]::IsNullOrWhiteSpace($dc)){ $dc='[]' }
      if(Test-Path $dp){ Remove-Item -Force $dp }
      Send-Response $stream 200 'application/json' $dc
    } elseif($path -like '/api/draft*'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $dp = Join-Path $base ("draft_$tid.json")
      if($method -eq 'POST'){
        $tr = $bodyIn.Trim()
        if($tr -eq '' -or $tr -eq '[]'){ if(Test-Path $dp){ Remove-Item -Force $dp } }
        else { [System.IO.File]::WriteAllText($dp, $bodyIn, (New-Object Text.UTF8Encoding($false))) }
        Send-Response $stream 200 'application/json' '{"ok":true}'
      } else {
        $dc = if(Test-Path $dp){ [System.IO.File]::ReadAllText($dp,[Text.Encoding]::UTF8) } else { '[]' }
        if([string]::IsNullOrWhiteSpace($dc)){ $dc='[]' }
        Send-Response $stream 200 'application/json' $dc
      }
    } elseif($path -like '/api/note*'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $np = Join-Path $base ("note_$tid.txt")
      if($method -eq 'POST'){
        if([string]::IsNullOrWhiteSpace($bodyIn)){ if(Test-Path $np){ Remove-Item -Force $np } }
        else { [System.IO.File]::WriteAllText($np, $bodyIn, (New-Object Text.UTF8Encoding($false))) }
        Send-Response $stream 200 'application/json' '{"ok":true}'
      } else {
        $nc = if(Test-Path $np){ [System.IO.File]::ReadAllText($np,[Text.Encoding]::UTF8) } else { '' }
        Send-Response $stream 200 'text/plain' $nc
      }
    } elseif($path -like '/api/seqnames*'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $sp = Join-Path $base ("seqnames_$tid.json")
      if($method -eq 'POST'){
        $tr = $bodyIn.Trim()
        if($tr -eq '' -or $tr -eq '{}'){ if(Test-Path $sp){ Remove-Item -Force $sp } }
        else { [System.IO.File]::WriteAllText($sp, $bodyIn, (New-Object Text.UTF8Encoding($false))) }
        Send-Response $stream 200 'application/json' '{"ok":true}'
      } else {
        $sc = if(Test-Path $sp){ [System.IO.File]::ReadAllText($sp,[Text.Encoding]::UTF8) } else { '{}' }
        if([string]::IsNullOrWhiteSpace($sc)){ $sc='{}' }
        Send-Response $stream 200 'application/json' $sc
      }
    } elseif($path -like '/api/billmeta*'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $sp = Join-Path $base ("billmeta_$tid.json")
      if($method -eq 'POST'){
        $tr = $bodyIn.Trim()
        if($tr -eq '' -or $tr -eq '{}'){ if(Test-Path $sp){ Remove-Item -Force $sp } }
        else { [System.IO.File]::WriteAllText($sp, $bodyIn, (New-Object Text.UTF8Encoding($false))) }
        Send-Response $stream 200 'application/json' '{"ok":true}'
      } else {
        $sc = if(Test-Path $sp){ [System.IO.File]::ReadAllText($sp,[Text.Encoding]::UTF8) } else { '{}' }
        if([string]::IsNullOrWhiteSpace($sc)){ $sc='{}' }
        Send-Response $stream 200 'application/json' $sc
      }
    } elseif($path -like '/api/rules*'){
      $rp = Join-Path $base 'estiasis_ai_rules.txt'
      if($method -eq 'POST'){
        if([string]::IsNullOrWhiteSpace($bodyIn)){ if(Test-Path $rp){ Remove-Item -Force $rp } }
        else { [System.IO.File]::WriteAllText($rp, $bodyIn, (New-Object Text.UTF8Encoding($false))) }
        Send-Response $stream 200 'application/json' '{"ok":true}'
      } else {
        $rc = if(Test-Path $rp){ [System.IO.File]::ReadAllText($rp,[Text.Encoding]::UTF8) } else { '' }
        Send-Response $stream 200 'text/plain' $rc
      }
    } elseif($path -like '/api/save*' -and $method -eq 'POST'){
      $plid = if($path -match 'pricelistId=(\d+)'){ $Matches[1] } else { '1' }
      $resp = ApiPost "api/Orders/Save?pricelistId=$plid" $bodyIn
      try { $o = $bodyIn | ConvertFrom-Json | Select-Object -First 1; if($o -and $o.Table_ID){ $dpp = Join-Path $base ("draft_$([int]$o.Table_ID).json"); if(Test-Path $dpp){ Remove-Item -Force $dpp } } } catch {}
      Send-Response $stream 200 'application/json' $resp
    } elseif($path -like '/api/print*' -and $method -eq 'POST'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $bill = if($path -match 'bill=(-?\d+)'){ $Matches[1] } else { '-1' }
      try { $pr2 = ApiPost "api/Orders/Print?tableId=$tid&printType=255&ordersOrderID=0&billNumber=$bill" ''; Send-Response $stream 200 'application/json' $pr2 }
      catch { $eb=''; try{ $rs=$_.Exception.Response.GetResponseStream(); $sr=New-Object IO.StreamReader($rs); $eb=$sr.ReadToEnd() }catch{}; LogLine ('PRINT tid='+$tid+' ERR='+$_.Exception.Message+' DETAIL='+$eb); Send-Response $stream 502 'application/json' ('{"error":'+(ConvertTo-Json ([string]$_.Exception.Message))+',"detail":'+(ConvertTo-Json ([string]$eb))+'}') }
    } elseif($path -like '/api/close*' -and $method -eq 'POST'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      $rcpt = if($path -match 'receipt=false'){ 'False' } else { 'True' }
      try { $cr = ApiPost "api/Orders/Close?tableId=$tid&billNumber=-1&paymentCode=1&room=0&receipt=$rcpt&forceClose=True" ''; LogLine ('CLOSE tid='+$tid+' receipt='+$rcpt+' OK result='+$cr); Send-Response $stream 200 'application/json' $cr }
      catch { $eb=''; try{ $rs=$_.Exception.Response.GetResponseStream(); $sr=New-Object IO.StreamReader($rs); $eb=$sr.ReadToEnd() }catch{}; LogLine ('CLOSE tid='+$tid+' ERR='+$_.Exception.Message+' DETAIL='+$eb); Send-Response $stream 502 'application/json' ('{"error":'+(ConvertTo-Json ([string]$_.Exception.Message))+',"detail":'+(ConvertTo-Json ([string]$eb))+'}') }
    } elseif($path -like '/api/cancel*' -and $method -eq 'POST'){
      $tid = if($path -match 'table=(\d+)'){ $Matches[1] } else { '0' }
      try { $cr = ApiPost "api/Orders/Cancel?tableId=$tid&billNumber=-1" ''; LogLine ('CANCEL tid='+$tid+' OK result='+$cr); Send-Response $stream 200 'application/json' $cr }
      catch { $eb=''; try{ $rs=$_.Exception.Response.GetResponseStream(); $sr=New-Object IO.StreamReader($rs); $eb=$sr.ReadToEnd() }catch{}; LogLine ('CANCEL tid='+$tid+' ERR='+$_.Exception.Message+' DETAIL='+$eb); Send-Response $stream 502 'application/json' ('{"error":'+(ConvertTo-Json ([string]$_.Exception.Message))+',"detail":'+(ConvertTo-Json ([string]$eb))+'}') }
    } elseif($path -like '/api/move*' -and $method -eq 'POST'){
      $from = if($path -match 'from=(\d+)'){ $Matches[1] } else { '0' }
      $to   = if($path -match 'to=(\d+)'){ $Matches[1] } else { '0' }
      $moved=$false; $emsg=$null
      try { $mr=ApiPost "api/Orders/ChangeTable?sourceTableId=$from&desticationTableId=$to&sourceBillnumber=0" ''; if($mr -match '"[Rr]esult"\s*:\s*false' -or $mr -match '^\s*false\s*$'){ $emsg='ChangeTable returned false' } else { $moved=$true } } catch { $emsg=[string]$_.Exception.Message }
      if($moved){
        $srcD = Join-Path $base ("draft_$from.json"); $dstD = Join-Path $base ("draft_$to.json")
        if(Test-Path $srcD){ try{ Move-Item -Force $srcD $dstD }catch{} }
        $srcN = Join-Path $base ("note_$from.txt"); $dstN = Join-Path $base ("note_$to.txt")
        if(Test-Path $srcN){ try{ Move-Item -Force $srcN $dstN }catch{} }
        Send-Response $stream 200 'application/json' '{"ok":true}'
      } else { LogLine ('MOVE from='+$from+' to='+$to+' ERR='+[string]$emsg); Send-Response $stream 502 'application/json' ('{"error":'+(ConvertTo-Json ([string]$emsg))+'}') }
    } elseif($path -like '/api/aifill*' -and $method -eq 'POST'){
      try {
        $inObj = $bodyIn | ConvertFrom-Json
        $note = [string]$inObj.note
        $lvl = 1; try{ if($inObj.level){ $lvl=[int]$inObj.level } }catch{}
        $req = Build-AiRequest $note $lvl $inObj.lnames
        if(-not $req.ok){ Send-Response $stream 200 'application/json' $req.out }
        else {
          for($pi=$script:aiPending.Count-1; $pi -ge 0; $pi--){ $pp=$script:aiPending[$pi]; if($pp.async.IsCompleted){ try{ $pp.ps.EndInvoke($pp.async) }catch{}; try{ $pp.ps.Dispose() }catch{}; $script:aiPending.RemoveAt($pi) } }
          $aps=[powershell]::Create(); $aps.RunspacePool=$aiPool
          [void]$aps.AddScript($aiWorker.ToString()).AddArgument($client).AddArgument($stream).AddArgument($req.bytes).AddArgument($req.hdr).AddArgument($script:errlog)
          $aasync=$aps.BeginInvoke()
          [void]$script:aiPending.Add(@{ ps=$aps; async=$aasync })
          $handedOff=$true
        }
      } catch { LogLine ('AIFILL ERR='+$_.Exception.Message); try{ Send-Response $stream 502 'application/json' ('{"error":'+(ConvertTo-Json ([string]$_.Exception.Message))+'}') }catch{} }
    } else {
      Send-Response $stream 404 'text/plain' 'not found'
    }
  } catch { LogLine ([string]$method+' '+[string]$path+' 500 ERR='+$_.Exception.Message+' @ '+$_.ScriptStackTrace); try { Send-Response $stream 500 'application/json' ('{"error":'+(ConvertTo-Json ([string]$_.Exception.Message))+'}') } catch {} } finally { try { if((-not $handedOff) -and $client){ $client.Close() } } catch {} }
}

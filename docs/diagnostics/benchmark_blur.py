import json,sys
from pathlib import Path
import numpy as np
sys.path[:0]=['backend','.']
from analyze_capture_bundle import analyze_capture
from cv_engine.universal import ManualTracker
captures=['HandsOnPhysics-2026-10-11T23-02-11-324Z.hop.json','HandsOnPhysics-2026-10-11T22-34-05-920Z.hop.json','HandsOnPhysics-2026-10-11T22-34-36-849Z.hop.json']
original=ManualTracker._foreground_continuation
results={}
for name in captures:
 result={}
 for enabled in (False,True):
  ManualTracker._foreground_continuation=original if enabled else lambda *a: None
  runs=[analyze_capture(Path('diagnostics/logs')/name) for _ in range(2)]
  rows=runs[0]['observations'];ms=[row['replay_worker_ms'] for run in runs for row in run['observations']]
  result['after' if enabled else 'before']={'frames':len(rows),'tracked':sum(r['tracked'] for r in rows),'metric_positions':sum(r.get('position') is not None for r in rows),'worker_median_ms':float(np.median(ms)),'worker_p95_ms':float(np.percentile(ms,95)), 'observations':[{'frame_id':r['frame_id'],'timestamp':r['timestamp'],'pixel':r.get('pixel'),'position':r.get('position'),'quality':r.get('physics_quality')} for r in rows]}
  print(name,'enabled',enabled,result['after' if enabled else 'before']['tracked'],float(np.median(ms)),flush=True)
 result.update(source_sha256=runs[0]['source_sha256'],capture=runs[0]['capture'])
 results[name]=result
ManualTracker._foreground_continuation=original
Path('docs/diagnostics/oct11_blur_metrics.json').write_text(json.dumps({'method':'Single process, OpenCV one thread and seed zero, two full replays per variant. Before disables only the added continuation; unchanged strict tracker and physics. Runs serial without other test/build jobs. No transport or sensor latency measured. Before then after order is not randomized.', 'captures':results},indent=2)+'\n')

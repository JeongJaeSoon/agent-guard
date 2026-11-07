#!/usr/bin/env python3
"""최종 공통 정책 primary JSON만으로 연구/공유용 SVG를 생성하고 원시 표본에서 독립 검산한다."""
import os
os.environ['MPLCONFIGDIR']='/workspace/agent-guard-lab/plot-cache'
import argparse,csv,hashlib,json,math,platform,statistics,textwrap
from collections import Counter
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
from matplotlib import pyplot as plt,font_manager
from matplotlib.lines import Line2D
VERS=['v3.6.13','v3.6.14','v3.6.15','v3.7.0','v3.7.1','v3.8.0','v3.8.1']
CASES=['small-clean','many-replacement-leaves','long-multiline']
CASE_LABEL={'small-clean':'정상 소출력','many-replacement-leaves':'다수 문자열 치환','long-multiline':'긴 여러 줄 문자열'}
DIMS=['phase','series','environment','distribution','scanner','host','audit','case','variant','workers','version','metric']
COLORS=['#175A93','#7F3C8D'];POINTS=[];CATALOG=[];MISSING=[]
def digest(data):return hashlib.sha256(data).hexdigest()
def canonical(v):return json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
def quantiles(values):
 if len(values)==1:return (values[0],)*3
 q=statistics.quantiles(values,n=4,method='inclusive');return statistics.median(values),q[0],q[2]
def same(a,b):return math.isclose(a,b,rel_tol=1e-12,abs_tol=1e-10)
def numeric_value(row,metric):
 if metric=='wall_ms':return row['wall_s']*1000
 if metric=='cpu_ms':return row['cpu_s']*1000
 if metric=='throughput_rps':return row['requests']/row['wall_s']
 return row[metric]
def status(delta,higher=False):
 if delta is None:return 'N/A'
 gain=delta if higher else -delta
 return 'G 개선 ≥10%' if gain>=10 else 'R 회귀 >5%' if gain< -5 else '기준 미만'
def setup_font():
 p=Path('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
 if not p.exists():raise RuntimeError('Noto CJK font unavailable; refuse unreadable Korean figures')
 font_manager.fontManager.addfont(str(p));name=font_manager.FontProperties(fname=str(p)).get_name()
 plt.rcParams.update({'font.family':name,'font.size':10,'axes.titlesize':12,'axes.labelsize':10,'xtick.labelsize':9,'ytick.labelsize':9,'axes.unicode_minus':False,'svg.fonttype':'path','svg.hashsalt':'agent-guard-public-versions-20261106','figure.facecolor':'white','savefig.facecolor':'white'})
 return {'path':str(p),'family':name,'sha256':digest(p.read_bytes()),'svg_fonttype':'path'}
def runtime_lookup(data,query,metric):
 result=[r for r in data['aggregates'] if r['metric']==metric and all(r.get(k)==v for k,v in query.items())]
 if len(result)>1:raise AssertionError(('ambiguous condition',query,metric))
 return result[0] if result else None
def verify_point(data,row,install=False):
 if install:
  attempted=[r for r in data['installation'] if r.get('environment')==row['environment'] and r.get('scenario')==row['scenario'] and ('v'+r['version'].lstrip('v'))==row['version'] and not r.get('warmup',False)]
  raw=[r for r in attempted if r.get('success',True)];planned=9
  values=[r[row['metric']] for r in raw if isinstance(r.get(row['metric']),(int,float))]
  ids=[str(r.get('raw_source'))+':'+str(r.get('raw_row',r.get('round'))) for r in raw]
 else:
  keys=[k for k in DIMS if k!='metric']
  attempted=[r for r in data['runtime'] if all(r.get(k)==row[k] for k in keys)]
  raw=[r for r in attempted if r.get('success',True) and r.get('eligible',True)]
  planned=16 if row['phase']=='rss' or row['series']=='load' else 14
  assert row['total_samples']==len(attempted)
  values=[numeric_value(r,row['metric']) for r in raw];ids=[r['sample_id'] for r in raw]
 assert len(attempted)==planned,('planned attempt count',row,len(attempted),planned)
 assert len(values)==row['n'],('raw eligible n',row,len(values))
 actual=quantiles(values)
 assert all(same(a,row[k]) for a,k in zip(actual,['median','p25','p75'])),('independent raw recheck failed',row,actual)
 return values,ids,planned

def record_point(data,figure,panel,line,row,scale,unit,install=False):
 values,ids,planned=verify_point(data,row,install)
 prefix='cross_variant_baseline' if row.get('variant')=='fused' else 'cumulative'
 delta=row.get(prefix+'_pct');higher=row['metric']=='throughput_rps'
 if delta is not None:
  source=data['installation_aggregates'] if install else data['aggregates']
  keys=['environment','scenario','metric'] if install else [k for k in DIMS if k not in ['version','variant']]
  references=[r for r in source if r['version']=='v3.6.13' and all(r.get(k)==row.get(k) for k in keys) and (install or r['variant']=='default')]
  assert len(references)==1;reference=references[0]
  assert min(row['n'],reference['n'])>=9 and row.get(prefix+'_valid_pairs',0)>=9
  assert same(delta,(row['median']/reference['median']-1)*100),('delta',row,reference)
  def rounds(condition):
   if install:
    rs=[r for r in data['installation'] if ('v'+r['version'].lstrip('v'))==condition['version'] and all(r.get(k)==condition.get(k) for k in ['environment','scenario']) and not r.get('warmup',False) and r.get('success',True)]
   else:rs=[r for r in data['runtime'] if all(r.get(k)==condition.get(k) for k in DIMS if k!='metric') and r.get('success',True) and r.get('eligible',True)]
   return {r['round'] for r in rs}
  assert row[prefix+'_valid_pairs']==len(rounds(row)&rounds(reference)),('paired guard',row)
 result={k:row.get(k) for k in DIMS};result.update(figure=figure,panel=panel,line=line,scenario=row.get('scenario'),source_unit=row['unit'],display_unit=unit,n=row['n'],planned_attempts=planned,plotted=row['n']>=9,source_median=row['median'],source_p25=row['p25'],source_p75=row['p75'],display_median=row['median']*scale,display_p25=row['p25']*scale,display_p75=row['p75']*scale,baseline_version='v3.6.13',baseline_comparison_kind=row.get(prefix+'_comparison_kind'),cumulative_pct=delta,threshold_status=status(delta,higher),source_aggregate_sha256=digest(canonical(row)),raw_values_sha256=digest(canonical(values)),selected_raw_ids=ids,raw_values=values,source_aggregate=row)
 if row['n']<9:
  for key in ['display_median','display_p25','display_p75']:result[key]=None
  result['threshold_status']='N/A — 유효 n<9'
 POINTS.append(result);return result

def draw_line(ax,data,figure,panel,line,query,metric,scale,unit,color,linestyle='-',marker='o',versions=VERS,x_positions=None,install=False):
 xs=[];ys=[];low=[];high=[];points=[];missing=[]
 if x_positions is None:x_positions=list(range(len(versions)))
 for version,x in zip(versions,x_positions):
  if install:
   matches=[r for r in data['installation_aggregates'] if r['metric']==metric and r['version']==version and all(r.get(k)==v for k,v in query.items())]
   assert len(matches)<=1;row=matches[0] if matches else None
  else:row=runtime_lookup(data,query|{'version':version},metric)
  if row is None:
   if install:attempted=[r for r in data['installation'] if r.get('environment')==query['environment'] and r.get('scenario')==query['scenario'] and ('v'+r['version'].lstrip('v'))==version and not r.get('warmup',False)]
   else:attempted=[r for r in data['runtime'] if r.get('version')==version and all(r.get(k)==v for k,v in query.items())]
   planned=9 if install else 16 if query.get('phase')=='rss' or query.get('series')=='load' else 14
   assert len(attempted)==planned,('N/A attempt count',figure,version,len(attempted),planned)
   MISSING.append({'figure':figure,'panel':panel,'line':line,'condition':query,'version':version,'metric':metric,'attempts':len(attempted),'eligible_rows':sum(r.get('success',True) and r.get('eligible',True) for r in attempted),'value':None,'reason':'No valid numeric aggregate; raw failures/absence preserved. N/A, never zero.'})
   missing.append((x,version));xs.append(x);ys.append(float('nan'));low.append(0);high.append(0);continue
  point=record_point(data,figure,panel,line,row,scale,unit,install);points.append((x,point))
  if row['n']<9:
   missing.append((x,version));xs.append(x);ys.append(float('nan'));low.append(0);high.append(0);continue
  xs.append(x);ys.append(point['display_median']);low.append((row['median']-row['p25'])*scale);high.append((row['p75']-row['median'])*scale)
 ax.errorbar(xs,ys,yerr=[low,high],color=color,linestyle=linestyle,marker=marker,markersize=4,linewidth=1.5,capsize=3,label=line)
 for x,point in points:
  if not point['plotted']:continue
  if point['n']!=point['planned_attempts']:ax.annotate('n='+str(point['n']),(x,point['display_median']),xytext=(0,-14),textcoords='offset points',ha='center',fontsize=8)
  symbol='G' if point['threshold_status'].startswith('G ') else 'R' if point['threshold_status'].startswith('R ') else ''
  if symbol:ax.annotate(symbol,(x,point['display_median']),xytext=(0,9),textcoords='offset points',ha='center',fontsize=8,color='#174C27' if symbol=='G' else '#9D231F',weight='bold')
 for x,_ in missing:ax.text(x,.035,'N/A',transform=ax.get_xaxis_transform(),ha='center',fontsize=8)
 counts=getattr(ax,'_eligible_ns',set())|{p['n'] for _,p in points};attempts=getattr(ax,'_attempt_ns',set())|{p['planned_attempts'] for _,p in points}
 ax._eligible_ns=counts;ax._attempt_ns=attempts
 if counts and attempts:
  label='유효 n='+str(min(counts))+(('–'+str(max(counts))) if len(counts)>1 else '')+' / 시도 '+str(max(attempts))
  existing=getattr(ax,'_n_note',None)
  if existing is None:ax._n_note=ax.text(.98,.98,label,transform=ax.transAxes,ha='right',va='top',fontsize=8)
  else:existing.set_text(label)
 return points

def style_axis(ax,unit,title,versions=VERS,fused=False):
 ax.set_title(title,loc='left',pad=13);ax.set_ylabel(unit);ax.grid(axis='y',alpha=.24);ax.set_axisbelow(True);ax.spines[['top','right']].set_visible(False)
 ticks=list(range(len(versions)));labels=[v.removeprefix('v') for v in versions]
 if fused:ticks+=[7];labels+=['3.8.1\nfused']
 ax.set_xticks(ticks,labels,rotation=15,ha='right');ax.set_xlim(-.35,7.45 if fused else 6.35)
 lower,upper=ax.get_ylim();ax.set_ylim(max(0,lower),upper+(upper-lower)*.1)

def env_info(data,env):
 infos=[r for r in data.get('context',{}).get('runtime_environments',[]) if r.get('environment')==env]
 assert len(infos)==1,('missing/ambiguous CPU environment metadata',env)
 return infos[0]
def title_and_footer(fig,title,info,extra,policy_label='공통 3정책 고정'):
 cpu=info.get('cpu_model','N/A');env=info['environment']
 fig.suptitle(title+'\n'+env+' | '+cpu,fontsize=14,y=.985)
 footer='기준 v3.6.13 · 중앙값/수염 P25–P75(IQR) · G: 개선 ≥10% / R: 회귀 >5% / 무표시: 기준 미만 · N/A는 0이 아님\n'
 footer+='실제 cgroup 2 CPU · 1 GiB · swap 0 · '+policy_label+' · '+extra
 if info.get('config_sha256'):footer+='\nscanner config SHA256 '+info['config_sha256'][:16]+'… (전체 해시는 figure-data.json 및 report/data.json)'
 fig.text(.015,.012,footer,ha='left',va='bottom',fontsize=8.3,linespacing=1.4)
 fig.subplots_adjust(top=.90,bottom=.12,hspace=.42,wspace=.25)
def save_figure(fig,out,filename,title,data_hash,png=False):
 path=out/(filename+'.svg');points=[p for p in POINTS if p['figure']==filename]
 metadata={'Date':None,'Creator':'Matplotlib '+matplotlib.__version__,'Title':title,'Description':'source-data-sha256='+data_hash+'; figure-numeric-sha256='+digest(canonical(points))+'; medians and IQR independently recomputed from selected raw samples.'}
 fig.savefig(path,metadata=metadata)
 if png:fig.savefig(out/(filename+'.png'),dpi=150)
 CATALOG.append({'figure':filename,'title':title,'svg':path.name,'png':filename+'.png' if png else None,'point_count':len(points),'selected_numeric_sha256':digest(canonical(points))})
 plt.close(fig)

def latency(data,out,profile,info,data_hash):
 scanner,host,env=profile;name=scanner+'-'+host+'-latency-cpu';fig,axes=plt.subplots(3,2,figsize=(14,12))
 for i,case in enumerate(CASES):
  for j,metric in enumerate(['wall_ms','cpu_ms']):
   ax=axes[i,j];q=dict(phase='runtime',series='versions',environment=env,distribution='standalone',scanner=scanner,host=host,audit='off',case=case,variant='default',workers=1)
   draw_line(ax,data,name,case+'-'+metric,'기본 경로',q,metric,1,'ms',COLORS[0]);style_axis(ax,'ms ↓ (감소가 유리)',CASE_LABEL[case]+' · '+('CLI 전체 지연' if j==0 else 'CLI 자손 CPU 합계')+' · 시도14회/버전')
 title_and_footer(fig,scanner+' scanner · '+host+' | 공개 기본 7버전: CLI 지연·CPU',info,'audit off · runtime/versions · workers=1 · 시작 비용 포함')
 save_figure(fig,out,name,'기본 7버전 CLI 지연·CPU',data_hash,png=scanner=='homebrew' and host=='codex')

def throughput(data,out,profile,info,data_hash):
 scanner,host,env=profile;name=scanner+'-'+host+'-throughput';fig,axes=plt.subplots(3,2,figsize=(14,12))
 for i,case in enumerate(CASES):
  for j,(series,workers,n) in enumerate([('versions',1,14),('load',4,16)]):
   ax=axes[i,j];q=dict(phase='runtime',series=series,environment=env,distribution='standalone',scanner=scanner,host=host,audit='off',case=case,variant='default',workers=workers)
   draw_line(ax,data,name,case+'-w'+str(workers),'기본 '+str(workers)+'동시',q,'throughput_rps',1,'req/s',COLORS[j]);style_axis(ax,'req/s ↑ (증가가 유리)',CASE_LABEL[case]+f' · {workers}동시 · 시도{n}회/버전')
 title_and_footer(fig,scanner+' scanner · '+host+' | 공개 기본 7버전: 처리량',info,'audit off · 단일 1/wall, 4동시 4/wall · 4요청 단일 wave이며 지속 부하가 아님')
 save_figure(fig,out,name,'기본 7버전 단일·4동시 처리량',data_hash)

def memory(data,out,profile,info,data_hash):
 scanner,host,env=profile;name=scanner+'-'+host+'-memory';fig,axes=plt.subplots(2,2,figsize=(14,10))
 for i,case in enumerate(CASES[1:]):
  for j,metric in enumerate(['max_child_rss_kib','rss_sum_peak_kib']):
   ax=axes[i,j]
   for k,workers in enumerate([1,4]):
    q=dict(phase='rss',series='rss',environment=env,distribution='standalone',scanner=scanner,host=host,audit='off',case=case,workers=workers)
    draw_line(ax,data,name,case+'-'+metric,'기본 '+str(workers)+'동시',q|{'variant':'default'},metric,1/1024,'MiB',COLORS[k],linestyle='-' if workers==1 else '--',marker='o' if workers==1 else 's')
    draw_line(ax,data,name,case+'-'+metric,'fused '+str(workers)+'동시',q|{'variant':'fused'},metric,1/1024,'MiB',COLORS[k],linestyle='None',marker='D' if workers==1 else '^',versions=['v3.8.1'],x_positions=[7])
   label='최대 개별 자식 peak RSS' if j==0 else '표본 프로세스 RSS 합의 최대'
   style_axis(ax,'MiB ↓ (감소가 유리)',CASE_LABEL[case]+' · '+label+' · 각 시도16회',fused=True);ax.legend(fontsize=8,loc='upper left',ncol=2)
 title_and_footer(fig,scanner+' scanner · '+host+' | 별도 RSS 계측: 기본 7버전 + 최종 fused',info,'phase=rss/series=rss만 사용 · RSS 합은 공유 페이지 중복·peak 누락 가능, 고유 물리 RAM이 아님')
 save_figure(fig,out,name,'별도 RSS 계측과 선택형 최종 경로',data_hash)

def installation(data,out,data_hash):
 env='linux-ci-install-2cpu-1g';info=env_info(data,env);name='installation-ci-cached-fresh';fig,axes=plt.subplots(2,2,figsize=(14,10))
 for ax,metric,scale,unit,label in zip(axes.flat,['wall_s','cpu_s','installed_bytes','download_bytes'],[1,1,1/1024**2,1/1024**2],['s','s','MiB','MiB'],['새 설치 경과시간','새 설치 자손 CPU 합계','설치된 일반 파일 크기 (논리 크기 합)','대상 다운로드 파일 크기 (실제 전송 제외)']):
  q=dict(environment=env,scenario='standalone-fresh-cached');draw_line(ax,data,name,metric,'cached 새 설치',q,metric,scale,unit,COLORS[0],install=True);style_axis(ax,unit+' ↓ (감소가 유리)',label+' · 시도9회/버전')
 title_and_footer(fig,'공개 기본 7버전 | 격리된 cached 새 설치 비용',info,'네트워크·bootstrap 최초 다운로드·최초 OS 의존성 설치 제외 · Python 운송 shim 비용 포함',policy_label='버전별 공개 payload 그대로')
 save_figure(fig,out,name,'CI cached 새 설치: 시간·CPU·설치/운송 크기',data_hash,png=True)

def main():
 p=argparse.ArgumentParser();p.add_argument('--data',required=True);p.add_argument('--out',required=True);a=p.parse_args();source=Path(a.data);data=json.loads(source.read_text());out=Path(a.out)
 assert data['runtime'] and all(r.get('policy_mode')=='common' for r in data['runtime']),'refuse mixing shipped-policy, local, or cancelled cohorts'
 profiles=sorted({(r['scanner'],r['host'],r['environment']) for r in data['runtime']});assert len(profiles)==4 and {(s,h) for s,h,_ in profiles}=={(s,h) for s in ['official','homebrew'] for h in ['claude','codex']},'all four final cohorts required'
 counts=Counter(r['environment'] for r in data['runtime']);assert set(counts.values())=={2939},('final frozen cohort incomplete',counts)
 for scanner,host,env in profiles:
  rows=[r for r in data['runtime'] if r['environment']==env]
  for key in ['scanner_sha256','config_sha256','deny_bash_sha256','deny_read_sha256']:assert len({r[key] for r in rows})==1,('effective bytes differ',env,key)
  info=env_info(data,env);assert info['cpu_max']=='200000 100000' and str(info['memory_max'])=='1073741824' and str(info['memory_swap_max'])=='0',('limits',info)
 font=setup_font();out.mkdir(parents=True,exist_ok=False);data_hash=digest(source.read_bytes())
 for profile in profiles:
  info=env_info(data,profile[2]);latency(data,out,profile,info,data_hash);throughput(data,out,profile,info,data_hash);memory(data,out,profile,info,data_hash)
 installation(data,out,data_hash)
 assert len(CATALOG)==13
 # Selected figure rows preserve full aggregate plus exact raw values/ids; originals remain untouched.
 doc={'scope':'Final strict-common-policy runtime CI cohorts plus separate CI cached published-payload installation. Separate environments/phases never pooled. Figures independently validate each selected aggregate against raw observations.','source_data':str(source),'source_data_sha256':data_hash,'figures':CATALOG,'points':POINTS,'missing':MISSING}
 (out/'figure-data.json').write_text(json.dumps(doc,ensure_ascii=False,indent=2)+'\n')
 cols=['figure','panel','line','environment','scanner','host','phase','series','scenario','variant','workers','version','metric','source_unit','display_unit','n','planned_attempts','plotted','source_median','source_p25','source_p75','display_median','display_p25','display_p75','baseline_version','cumulative_pct','threshold_status','source_aggregate_sha256','raw_values_sha256']
 with (out/'figure-data.csv').open('w') as f:
  w=csv.DictWriter(f,fieldnames=cols,extrasaction='ignore');w.writeheader();w.writerows(POINTS)
 exported=list(csv.DictReader((out/'figure-data.csv').open()));assert len(exported)==len(POINTS)
 for row,point in zip(exported,POINTS):
  for k in ['n','planned_attempts','source_median','source_p25','source_p75','display_median','display_p25','display_p75']:
   assert (row[k]=='' if point[k] is None else float(row[k])==point[k])
 numeric_hash=digest(canonical([{k:p[k] for k in cols} for p in POINTS]))
 validation={'all_13_svgs_generated':True,'raw_independent_median_iqr_n_verified':True,'independent_cumulative_ratio_and_same_round_guard_verified':True,'figure_csv_json_numeric_match':True,'selected_points':len(POINTS),'missing_numeric_points':len(MISSING),'attempt_counts_verified':True,'eligible_n_not_assumed_equal_planned':True,'plotted_points':sum(p['plotted'] for p in POINTS),'data_sha256':data_hash,'selected_numeric_sha256':numeric_hash,'script':str(Path(__file__).resolve()),'script_sha256':digest(Path(__file__).read_bytes()),'matplotlib_version':matplotlib.__version__,'python_version':platform.python_version(),'font':font,'mplconfigdir':os.environ['MPLCONFIGDIR'],'primary_rows':len(data['runtime']),'primary_cohorts':dict(counts),'svg_font_paths_embedded':True,'PNG_note':'Only representative homebrew-Codex CLI and installation figures also saved as PNG; SVG is the complete artifact set.'}
 (out/'figure-validation.json').write_text(json.dumps(validation,ensure_ascii=False,indent=2)+'\n')
 readme=['# 독립 그래프 산출물','', '각 SVG는 외부 폰트/CDN 없이 열리도록 글꼴을 path로 포함한다. 선은 중앙값, 수염은 P25–P75(IQR)이다. 지연·CPU·메모리·설치 비용은 감소가 유리하고 처리량은 증가가 유리하다. G/R 텍스트와 선/점 모양을 사용하므로 색만으로 판정을 구분하지 않는다. G는 기준 v3.6.13 대비10% 이상 개선, R은5% 초과 회귀다. N/A를0으로 채우지 않는다.','', '같은2CPU·1GiB라도 cohort별 CPU 모델이 다르므로 서로 다른 그림의 절대 ms 차이를 scanner/host 단독 원인으로 설명하지 않는다. 메모리는 별도 RSS phase만 사용하며 표본 RSS 합은 고유 물리 메모리가 아니다. 기본 지연·CPU 그림에는 optional 경로를 섞지 않았고, RSS에서만 동일 block의 최종 fused를 별도 endpoint로 표시했다.','', '[선택 집계 JSON 및 원시 표본 id](figure-data.json) · [선택 집계 CSV](figure-data.csv) · [독립 재계산·도구 검증](figure-validation.json) · [파일 해시](figure-hashes.json)','', '재현: `python analysis/plot_figures.py --data report/data.json --out <new figures directory>`','']
 for item in CATALOG:readme+=[f"- [{item['figure']}]({item['svg']}): {item['title']}"]
 (out/'README.ko.md').write_text('\n'.join(readme)+'\n')
 hashes={f.name:digest(f.read_bytes()) for f in sorted(out.iterdir()) if f.is_file()};(out/'figure-hashes.json').write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(validation,ensure_ascii=False))
if __name__=='__main__':main()

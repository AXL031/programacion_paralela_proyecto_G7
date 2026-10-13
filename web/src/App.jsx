import React, {useState,useEffect,useRef} from "react";
import {createRoot} from "react-dom/client";

const format=(value,decimals=0)=>value==null?"—":new Intl.NumberFormat("es-PE",{minimumFractionDigits:decimals,maximumFractionDigits:decimals}).format(value);
const runLabels={queued:"En cola",preparing:"Preparando datos",running:"Entrenando",completed:"Entrenamiento completado",failed:"Entrenamiento interrumpido"};
async function api(path,body){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),10000);
 try{
  const response=await fetch("/api/v1"+path,{method:body?"POST":"GET",credentials:"same-origin",headers:body?{"Content-Type":"application/json"}:{},body:body?JSON.stringify(body):undefined,signal:controller.signal});
  const data=await response.json();if(!response.ok){const error=new Error(data.error||"Servicio no disponible.");error.status=response.status;throw error}return data;
 }finally{clearTimeout(timer)}
}
function Brand(){return <a className="brand" href="#explorar"><span className="brand-icon" aria-hidden="true">p</span><span>Pulso<span className="brand-sub">Transporte</span></span></a>}
function App(){
 const [session,setSession]=useState(undefined);
 useEffect(()=>{api("/auth/session").then(setSession).catch(()=>setSession(null))},[]);
 if(session===undefined)return <div className="login-page"><Brand/><p>Preparando el proyecto…</p></div>;
 if(!session)return <Login onLogin={setSession}/>;
 return <Project session={session} onLogout={()=>setSession(null)}/>;
}
function Login({onLogin}){
 const [username,setUsername]=useState("demo"),[password,setPassword]=useState(""),[error,setError]=useState(""),[busy,setBusy]=useState(false);
 async function submit(event){event.preventDefault();setBusy(true);setError("");try{onLogin(await api("/auth/login",{username,password}))}catch(e){setError(e.message)}finally{setBusy(false)}}
 return <div className="login-page"><Brand/><section className="panel login-panel"><p className="eyebrow">PROYECTO G7 · ACCESO</p><h1>Tu espacio<br/><span>de movilidad.</span></h1><p className="muted">Inicia sesión para explorar los datos, entrenar y observar el clúster.</p>{error&&<p role="alert" className="alert">{error}</p>}<form onSubmit={submit}><label htmlFor="username">Usuario</label><input id="username" autoComplete="username" value={username} onChange={e=>setUsername(e.target.value)} required/><label htmlFor="password">Contraseña</label><input id="password" type="password" autoComplete="current-password" value={password} onChange={e=>setPassword(e.target.value)} required/><button className="primary" disabled={busy}>{busy?"Verificando…":"Iniciar sesión →"}</button></form><p className="scope-note">Sesión protegida de 30 minutos. Las credenciales se preparan al iniciar la demo.</p></section></div>;
}
function Project({session,onLogout}){
 const [dataset,setDataset]=useState(null),[model,setModel]=useState(null),[config,setConfig]=useState(null),[cluster,setCluster]=useState(null),[run,setRun]=useState(null),[impact,setImpact]=useState(null);
 const [zone,setZone]=useState("161"),[origin,setOrigin]=useState(""),[workers,setWorkers]=useState(2),[prediction,setPrediction]=useState(null),[observations,setObservations]=useState([]),[losses,setLosses]=useState([]);
 const [error,setError]=useState(""),[predicting,setPredicting]=useState(false),[starting,setStarting]=useState(false),[connection,setConnection]=useState("Conectando");
 const socket=useRef(null),pending=useRef(new Map()),selectedRun=useRef(null),mounted=useRef(true),modelRef=useRef(null),datasetRef=useRef(null);
 const date=(value,day=true)=>new Intl.DateTimeFormat("es-PE",{timeZone:dataset?.timezone||"America/New_York",...(day?{day:"2-digit",month:"short"}:{}),hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).format(new Date(value));
 function receiveRun(next){
  if(!next)return;setRun(next);selectedRun.current=next.run_id;
  const loss=next.progress?.objective_loss,step=next.progress?.step;
  if(step>0&&Number.isFinite(loss))setLosses(previous=>{
   const same=previous[0]?.run===next.run_id?previous:[];
   if(same.at(-1)?.step===step)return same;
   return [...same,{run:next.run_id,step,value:loss}].slice(-240);
  });
 }
 async function loadDataset(){const next=await api("/datasets/current");if(!mounted.current)return;datasetRef.current=next;setDataset(next);setZone(previous=>next.zones.some(z=>String(z.id)===previous)?previous:String(next.zones[0].id));setOrigin(previous=>{const time=Date.parse(previous);return time>=Date.parse(next.period_start)+next.window_minutes*60000&&time<Date.parse(next.period_end_exclusive)?previous:new Date(Date.parse(next.period_end_exclusive)-13*next.window_minutes*60000).toISOString()})}
 useEffect(()=>{
  mounted.current=true;
  let retry,timer,stopped=false;
  async function setup(){try{await loadDataset();setConfig(await api("/training-config"));const next=await api("/models/current");if(!stopped){modelRef.current=next;setModel(next)}}catch(e){if(e.status===401){onLogout();return}if(!stopped)setError("Esperando datos y servicios. La pantalla volverá a comprobarlos.")}if(!stopped&&!datasetRef.current)retry=setTimeout(setup,4000)}
  function connect(){
   if(stopped)return;
   const ws=new WebSocket(`${location.protocol==="https:"?"wss":"ws"}://${location.host}/api/v1/events`);socket.current=ws;
   ws.onopen=()=>{setConnection("En vivo · WebSocket");if(selectedRun.current)ws.send(JSON.stringify({type:"watch",run_id:selectedRun.current}))};
   ws.onmessage=event=>{
    if(stopped)return;
    const data=JSON.parse(event.data);
    if(data.type==="prediction"){
     const request=pending.current.get(data.request_id);if(request){pending.current.delete(data.request_id);if(data.error){const e=new Error(data.error);e.fromServer=true;request.reject(e)}else request.resolve(data.prediction)}return;
    }
    if(data.type!=="snapshot")return;
    setCluster(data.cluster_available?data.cluster:null);receiveRun(data.run);
    const next=data.model;
    if(next){const changed=next.version!==modelRef.current?.version;modelRef.current=next;if(changed||!next.ready)setModel(next)}
    if(next?.ready&&datasetRef.current&&next.dataset_id!==datasetRef.current.dataset_id)loadDataset().catch(()=>{});
   };
   ws.onerror=()=>setConnection("Reconectando");
   ws.onclose=()=>{
    socket.current=null;for(const request of pending.current.values())request.reject(new Error("Conexión interrumpida."));pending.current.clear();
    if(!stopped){setConnection("Reconectando · REST disponible");timer=setTimeout(async()=>{try{await api("/auth/session");connect()}catch(e){if(e.status===401)onLogout();else if(!stopped)connect()}},2000)}
   };
  }
  setup();connect();
  return()=>{stopped=true;mounted.current=false;clearTimeout(retry);clearTimeout(timer);socket.current?.close();for(const request of pending.current.values())request.reject(new Error("Sesión terminada."));pending.current.clear()};
 },[]);
 useEffect(()=>{if(dataset&&model?.ready&&model.dataset_id===dataset.dataset_id){api("/impact").then(setImpact).catch(()=>{});if(origin)consult().catch(()=>{})}},[dataset?.dataset_id,model?.version]);
 async function livePrediction(input){
  if(socket.current?.readyState!==WebSocket.OPEN)return api("/predictions",input);
  const id=crypto.randomUUID();
  try{return await new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{pending.current.delete(id);reject(new Error("Evento sin respuesta."))},5000);
   pending.current.set(id,{resolve:value=>{clearTimeout(timer);resolve(value)},reject:e=>{clearTimeout(timer);reject(e)}});
   socket.current.send(JSON.stringify({type:"predict",request_id:id,request:input}));
  })}catch(e){if(e.fromServer)throw e;return api("/predictions",input)}
 }
 async function consult(event){
  event?.preventDefault();if(predicting||!dataset||!model?.ready||model.dataset_id!==dataset.dataset_id)return;
  setPredicting(true);setError("");
  try{
   const p=await livePrediction({dataset_id:dataset.dataset_id,zone_id:Number(zone),forecast_origin:origin,horizon_minutes:dataset.window_minutes});if(!mounted.current)return;setPrediction(p);
   const time=Date.parse(p.forecast_origin),start=new Date(Math.max(Date.parse(dataset.period_start),time-4*3600000)).toISOString(),end=new Date(Math.min(Date.parse(dataset.period_end_exclusive),time+3600000)).toISOString();
   const rows=await api("/observations?"+new URLSearchParams({zone_id:p.zone_id,start,end}));if(mounted.current)setObservations(rows.windows);
  }catch(e){if(e.status===401)onLogout();else setError(e.message)}finally{if(mounted.current)setPredicting(false)}
 }
 async function train(){
  setStarting(true);setError("");setLosses([]);
  try{const next=await api("/training-runs",{...config,workers});receiveRun(next);if(socket.current?.readyState===WebSocket.OPEN)socket.current.send(JSON.stringify({type:"watch",run_id:next.run_id}))}catch(e){setError(e.message)}finally{setStarting(false)}
 }
 async function logout(){try{await api("/auth/logout",{})}finally{onLogout()}}
 const ready=model?.ready&&model.dataset_id===dataset?.dataset_id;
 const active=run&&!["completed","failed"].includes(run.status)||!!cluster?.active_run;
 const percent=run?.status==="completed"?100:run?.progress?.total_steps?Math.round(100*run.progress.step/run.progress.total_steps):0;
 const origins=[];
 if(dataset)for(let time=Date.parse(dataset.period_start)+dataset.window_minutes*60000;time<Date.parse(dataset.period_end_exclusive);time+=dataset.window_minutes*60000)origins.push(new Date(time).toISOString());
 const resultZone=dataset?.zones.find(z=>z.id===prediction?.zone_id);
 const quality=model?.evaluation?.test;
 const period=dataset?new Intl.DateTimeFormat("es-PE",{timeZone:dataset.timezone,day:"2-digit",month:"short",year:"numeric"}).format(new Date(dataset.period_start))+" — "+new Intl.DateTimeFormat("es-PE",{timeZone:dataset.timezone,day:"2-digit",month:"short"}).format(new Date(Date.parse(dataset.period_end_exclusive)-1)):"Cargando datos…";
 return <>
 <header className="topbar"><Brand/><nav aria-label="Navegación"><a href="#explorar">Explorar</a><a href="#entrenamiento">Entrenamiento</a><a href="#telemetria">Clúster</a><a href="#impacto">Impacto</a></nav><div className="user-tools"><span>{session.username}</span><button className="logout" onClick={logout}>Cerrar sesión</button></div></header>
 <main><div className="heading"><div><p className="eyebrow">MOVILIDAD URBANA / NUEVA YORK</p><h1>El próximo intervalo,<br/><span>con datos.</span></h1><p className="lead">Explora la actividad de transporte por zona y observa<br className="desktop"/> cómo un clúster aprende del histórico.</p></div><div className="period-note"><span className="tiny-label">PERÍODO DISPONIBLE</span><strong>{period}</strong><span>Hora de Nueva York · {dataset?.timezone||"America/New_York"}</span><span className="history-badge">Reproducción histórica</span><span className="connection" role="status">{connection}</span></div></div>
 {error&&<div className="alert" role="alert">{error}</div>}
 <section className="stats" aria-label="Resumen del dataset"><Stat title="Viajes válidos" value={format(dataset?.stats.persisted)} note="Datos reales · NYC TLC"/><Stat title="Zonas disponibles" value={format(dataset?.zones.length)} note="Ventanas de 15 minutos"/><Stat title="Trabajadores conectados" value={format(cluster?.workers.length)} note="Maestro y trabajadores por TCP"/><Stat title="Modelo publicado" value={ready?"Disponible":"Preparando"} note={model?.version?"Versión "+model.version.slice(-8):"Entrena una versión"}/></section>
 <div className="workspace" id="explorar"><section className="panel query-panel"><SectionHeading number="01" label="EXPLORAR" title="Consulta una zona"/><p className="muted">Selecciona un momento del histórico para estimar los siguientes 15 minutos.</p><form onSubmit={consult}><label htmlFor="zone">Zona de recogida</label><select id="zone" disabled={!ready||predicting} value={zone} onChange={e=>setZone(e.target.value)}>{dataset?.zones.map(z=><option key={z.id} value={z.id}>{z.name} · {z.borough}</option>)}</select><label htmlFor="origin">Inicio del intervalo <span className="label-note">Nueva York</span></label><select id="origin" disabled={!ready||predicting} value={origin} onChange={e=>setOrigin(e.target.value)}>{origins.map(time=><option key={time} value={time}>{date(time)}</option>)}</select><button className="primary" disabled={!ready||predicting}>{predicting?"Calculando…":"Consultar actividad ↗"}</button></form><div className="scope-note"><p>Se estiman <strong>viajes registrados</strong>. Estos datos no miden solicitudes rechazadas ni demanda no atendida.</p></div></section>
 <section className="panel result-panel" aria-live="polite"><div className="result-top"><div><p className="eyebrow">SIGUIENTES 15 MINUTOS</p><h2>{resultZone?.name||"Selecciona una consulta"}</h2></div>{prediction&&<span className="tag">{{train:"Entrenamiento",validation:"Validación",test:"Prueba"}[prediction.evaluation_period]}</span>}</div><div className="prediction-value"><strong>{format(prediction?.predicted_observed_trips,1)}</strong><span>viajes estimados</span></div><div className="result-comparison"><div><span>Intervalo anterior</span><strong>{format(prediction?.previous_observed_trips)}</strong></div><div><span>Registro observado</span><strong>{format(prediction?.actual_observed_trips)}</strong></div><div><span>Respuesta</span><strong>{prediction?format(prediction.latency_ms,1)+" ms":"—"}</strong></div></div><div className="result-footer"><span>{prediction?date(prediction.forecast_origin)+" → "+date(Date.parse(prediction.forecast_origin)+prediction.horizon_minutes*60000,false):"La estimación usa información previa al intervalo."}</span><span>{prediction&&"Versión "+prediction.model_version.slice(-8)+(prediction.cache_hit?" · caché":" · memoria")}</span></div></section></div>
 <section className="panel chart-panel"><div className="chart-heading"><div><p className="eyebrow">CONTEXTO DE LA CONSULTA</p><h2>Actividad registrada</h2></div><div className="legend"><span><i className="legend-history"/> Histórico</span><span><i className="legend-prediction"/> Estimación</span></div></div><ActivityChart rows={observations} prediction={prediction} date={date}/><p className="chart-note">El registro observado del intervalo consultado se muestra para comparar; no se utiliza como entrada de la predicción.</p></section>
 <div className="training-layout" id="entrenamiento"><section className="panel training-panel"><SectionHeading number="02" label="ENTRENAMIENTO DISTRIBUIDO" title="El clúster, en acción"/><p className="muted">Entrena una nueva versión mientras consultas el modelo publicado.</p><div className="training-controls"><label htmlFor="workers">Trabajadores<select id="workers" disabled={active||starting} value={workers} onChange={e=>setWorkers(Number(e.target.value))}><option value="1">1 trabajador</option><option value="2">2 trabajadores</option></select></label><button className="secondary" disabled={!config||!dataset||(cluster?.workers.length||0)<workers||active||starting} onClick={train}>{starting?"Iniciando…":"Entrenar modelo →"}</button></div><div className="run-header"><strong>{run?runLabels[run.status]:"Sin entrenamiento activo"}</strong><span>{run?percent+"%":"—"}</span></div><div className="progress-track" role="progressbar" aria-label="Progreso de entrenamiento" aria-valuemin="0" aria-valuemax="100" aria-valuenow={percent}><div style={{width:percent+"%"}}/></div><p className="run-detail">{run?.status==="completed"?"La versión "+run.artifact_version.slice(-8)+" está publicada.":run?.status==="failed"?"El entrenamiento se interrumpió; se conserva el modelo anterior.":run?.progress?.step?`Época ${run.progress.epoch} · ${format(run.progress.step)} de ${format(run.progress.total_steps)} pasos`:"La nueva versión se publica después de su validación."}</p><div className="worker-list">{cluster?.workers.map(w=><span className="worker-chip" key={w.worker_id}><span className={"dot"+(w.busy?" busy":"")}/>{w.worker_id.slice(0,8)} · {w.busy?"calculando":"listo"}</span>)}</div>{run&&<p className="run-id">{run.run_id}</p>}</section>
 <section className="panel quality-panel"><p className="eyebrow">CALIDAD DEL MODELO</p><h2>Comparar antes de publicar</h2><p className="muted">La elección usa validación. La tabla muestra el período de prueba.</p><table><thead><tr><th>Indicador</th><th>Publicado</th><th>Referencia</th></tr></thead><tbody><tr><th>MAE (viajes)</th><td>{format(quality?.model.mae,3)}</td><td>{format(quality?.persistence_baseline.mae,3)}</td></tr><tr><th>RMSE (viajes)</th><td>{format(quality?.model.rmse,3)}</td><td>{format(quality?.persistence_baseline.rmse,3)}</td></tr></tbody></table><p className="quality-note">{model?.method==="persistence"?"Validación eligió repetir el intervalo anterior. No hubo mejora válida de SGD.":"La versión se selecciona con validación. Referencia: repetir el intervalo anterior."}</p></section></div>
 <section className="panel telemetry-panel" id="telemetria"><div className="chart-heading"><div><p className="eyebrow">03 TELEMETRÍA</p><h2>Recursos del clúster</h2></div><span className="tag">{connection}</span></div><p className="muted">Mediciones del proceso Go. CPU: 100% equivale a un núcleo. RAM: memoria residente, en MiB.</p><div className="table-scroll"><table className="telemetry-table"><thead><tr><th>Nodo</th><th>Estado</th><th>CPU</th><th>RAM</th><th>Última muestra</th></tr></thead><tbody><ResourceRow name="Maestro" state={cluster?.active_run?"Coordinando":"Listo"} sample={cluster?.master}/>{cluster?.workers.map(w=><ResourceRow key={w.worker_id} name={"Worker "+w.worker_id.slice(0,8)} state={w.busy?"Calculando":"Listo"} sample={w.telemetry}/>)}</tbody></table></div><div className="loss-heading"><span>Pérdida del lote · objetivo normalizado</span><strong>{format(run?.progress?.objective_loss,6)}</strong></div><LossChart points={losses}/><p className="chart-note">Se muestra la pérdida reportada por el entrenamiento, sin mezclarla con MAE/RMSE. Los eventos llegan por WebSocket; las muestras de recursos se toman cada segundo y los workers las envían cada dos segundos.</p></section>
 <section className="panel impact-panel" id="impacto"><p className="eyebrow">04 IMPACTO Y ALCANCE</p><h2>Datos para planificar el transporte</h2><p>{impact?.question||"¿Cómo anticipar la actividad registrada por zona e intervalo para apoyar la planificación del transporte?"}</p><p className="muted">Comparar zonas y horarios permite explorar dónde y cuándo se concentra la actividad registrada. Los pronósticos se evalúan frente a una referencia temporal antes de usarse.</p><h3>Actividad observada por distrito</h3><div className="boroughs">{impact?.boroughs.map(b=><div className="borough" key={b.borough}><div><span>{b.borough}</span><strong>{format(b.observed_trips)} <small>viajes · {format(100*b.share,1)}%</small></strong></div><div className="borough-track"><span style={{width:100*b.share+"%"}}/></div></div>)}</div><p className="scope-note">{impact?.limitation||"Yellow Taxi registra viajes completados. No mide demanda no atendida, disponibilidad de vehículos ni desigualdad de acceso."} El impacto operativo es una propuesta de uso; requiere validación con responsables de transporte.</p></section>
 <footer><span><strong>Pulso</strong> · Programación concurrente y paralela</span><span>Fuente: NYC Taxi &amp; Limousine Commission</span></footer></main></>;
}
function Stat({title,value,note}){return <div className="stat"><span>{title}</span><strong className={title==="Modelo publicado"?"model-status":""}>{value}</strong><small>{note}</small></div>}
function SectionHeading({number,label,title}){return <div className="panel-heading"><span className="section-number">{number}</span><div><p className="eyebrow">{label}</p><h2>{title}</h2></div></div>}
function ResourceRow({name,state,sample}){const stale=!sample?.available||Date.now()-Date.parse(sample.sampled_at)>7000;return <tr><th>{name}</th><td>{stale?"Sin muestra reciente":state}</td><td>{stale?"—":format(sample.cpu_percent,1)+"%"}</td><td>{stale?"—":format(sample.rss_bytes/1048576,1)+" MiB"}</td><td>{sample?.sampled_at?new Intl.DateTimeFormat("es-PE",{hour:"2-digit",minute:"2-digit",second:"2-digit",hourCycle:"h23"}).format(new Date(sample.sampled_at)):"—"}</td></tr>}
function ActivityChart({rows,prediction,date}){
 const ref=useRef(null),[width,setWidth]=useState(600);
 useEffect(()=>{const observer=new ResizeObserver(entries=>setWidth(Math.max(300,entries[0].contentRect.width)));if(ref.current)observer.observe(ref.current);return()=>observer.disconnect()},[]);
 const height=215,left=36,right=15,top=20,bottom=35,max=Math.max(4,...rows.map(r=>r.observed_trips),prediction?.predicted_observed_trips||0)*1.15;
 const x=i=>left+i*(width-left-right)/Math.max(1,rows.length-1),y=v=>height-bottom-v/max*(height-top-bottom);
 const points=rows.map((r,i)=>`${x(i)},${y(r.observed_trips)}`).join(" "),index=rows.findIndex(r=>Date.parse(r.start)===Date.parse(prediction?.forecast_origin));
 return <div className="chart" ref={ref}>{rows.length?<svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Viajes por intervalo y estimación">{[0,1,2,3].map(i=><g key={i}><line x1={left} y1={y(max*i/3)} x2={width-right} y2={y(max*i/3)} stroke="#e2e6dd" strokeDasharray="3 5"/><text x={left-7} y={y(max*i/3)+3} textAnchor="end" fill="#738078" fontSize="10">{format(max*i/3)}</text></g>)}<polygon points={`${x(0)},${y(0)} ${points} ${x(rows.length-1)},${y(0)}`} fill="#edf2e9"/><polyline points={points} fill="none" stroke="#345e49" strokeWidth="2.4"/>{rows.map((r,i)=>i%Math.max(1,Math.floor(rows.length/(width<450?3:5)))===0?<text key={i} x={x(i)} y={height-8} textAnchor="middle" fill="#738078" fontSize="10">{date(r.start,false)}</text>:null)}{index>=0&&<g><line x1={x(index)} x2={x(index)} y1={top} y2={y(0)} stroke="#db653c" strokeDasharray="4 4"/><circle cx={x(index)} cy={y(prediction.predicted_observed_trips)} r="5" fill="#db653c" stroke="white"/><text x={Math.max(left,Math.min(width-105,x(index)+8))} y={Math.max(14,y(prediction.predicted_observed_trips)-12)} fill="#a84a2a" fontSize="11">Estimación: {format(prediction.predicted_observed_trips,1)}</text></g>}</svg>:<p className="empty-state">Consulta una zona para ver su evolución.</p>}</div>;
}
function LossChart({points}){if(points.length<2)return <div className="loss-empty">{points.length?"Recibiendo las primeras muestras…":"Inicia un entrenamiento para ver su pérdida."}</div>;const max=Math.max(...points.map(p=>p.value),0.00001);const path=points.map((p,i)=>`${10+i*630/(points.length-1)},${120-105*p.value/max}`).join(" ");return <><svg className="loss-chart" viewBox="0 0 650 140" role="img" aria-label="Pérdida del entrenamiento en tiempo real"><line x1="10" x2="640" y1="120" y2="120" stroke="#e2e6dd"/><polyline points={path} fill="none" stroke="#345e49" strokeWidth="2.5" vectorEffect="non-scaling-stroke"/></svg><div className="loss-axis"><span>Paso {format(points[0].step)}</span><span>Paso {format(points.at(-1).step)}</span></div></>}

createRoot(document.getElementById("root")).render(<App/>);

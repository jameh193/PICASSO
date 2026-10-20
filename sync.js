import {initializeApp} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js';
import {initializeFirestore,persistentLocalCache,persistentMultipleTabManager,doc,getDoc,collection,query,where,onSnapshot,writeBatch} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js';
import {getAuth,onAuthStateChanged,signInAnonymously,signInWithEmailAndPassword,signOut} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js';
import {firebaseConfig} from './firebase-config.js';

const app=initializeApp(firebaseConfig);
const fs=initializeFirestore(app,{localCache:persistentLocalCache({tabManager:persistentMultipleTabManager()})});
const auth=getAuth(app);
const FB=window.FB={loaded:false,isAdmin:false,uid:null};
const R={bookings:new Map(),busy:new Map()};
const shadow=new Map();
let cfgJson='',unsubs=[];

const J=v=>JSON.stringify(v,(k,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:1)):x);
// هر نوبتِ فعال، برای هر بازهٔ زمانی‌اش یک سند busy/{تاریخ_دقیقه} می‌گیرد؛ همین از رزرو همزمان یک ساعت جلوگیری می‌کند
const slotsOf=b=>{if(!active(b))return[];const t=toMin(b.time),out=[];for(let i=0;i<b.n;i++)out.push(`${b.date}_${t+i*db.settings.slot}`);return out};
const soft=()=>{if(!FB.loaded)return;if($dlg.open||/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName))return;const y=scrollY;render();scrollTo(0,y)};
function rebuild(){
  db.bookings=[...R.bookings.values()];
  const m={};for(const s of R.busy.values())(m[s.date]??=[]).push(s.t);
  window.BUSY=m;
}

FB.push=async()=>{
  if(!FB.uid||!FB.loaded)return;
  const batch=writeBatch(fs),touched=[];let n=0;
  for(const b of db.bookings){
    if(!b.uid)b.uid=FB.uid;
    const json=J(b),slots=slotsOf(b),old=shadow.get(b.id);
    if(old&&old.json===json)continue;
    batch.set(doc(fs,'bookings',b.id),JSON.parse(json));n++;
    const os=old?old.slots:[];
    for(const id of slots)if(!os.includes(id)){const [d,t]=id.split('_');batch.set(doc(fs,'busy',id),{date:d,t:+t,bid:b.id});n++}
    for(const id of os)if(!slots.includes(id)){batch.delete(doc(fs,'busy',id));n++}
    shadow.set(b.id,{json,slots});touched.push(b.id);
  }
  if(FB.isAdmin){
    const cfg={settings:{...db.settings},services:db.services};delete cfg.settings.pin;
    const cj=J(cfg);if(cj!==cfgJson){batch.set(doc(fs,'config','main'),JSON.parse(cj));cfgJson=cj;n++}
  }
  if(!n)return;
  try{await batch.commit()}
  catch(e){console.error(e);touched.forEach(id=>shadow.delete(id));toast('ذخیره نشد. اگر این ساعت را رزرو می‌کردید، احتمالاً همین حالا کس دیگری گرفته است.');rebuild();render()}
};

function subscribe(){
  unsubs.forEach(u=>u());unsubs=[];
  const fail=e=>{console.error(e);FB.loaded=true;soft()};
  unsubs.push(onSnapshot(doc(fs,'config','main'),snap=>{
    if(snap.exists()){
      const d=snap.data();
      db.settings=Object.assign(DEF().settings,d.settings||{});
      if(Array.isArray(d.services))db.services=d.services;
      cfgJson=J({settings:db.settings,services:db.services});
    }else if(FB.isAdmin){cfgJson='';FB.loaded=true;FB.push()}
    FB.loaded=true;soft();
  },fail));
  unsubs.push(onSnapshot(collection(fs,'busy'),snap=>{R.busy=new Map(snap.docs.map(d=>[d.id,d.data()]));rebuild();soft()},fail));
  const q=FB.isAdmin?collection(fs,'bookings'):query(collection(fs,'bookings'),where('uid','==',FB.uid));
  unsubs.push(onSnapshot(q,snap=>{
    R.bookings=new Map(snap.docs.map(d=>[d.id,d.data()]));
    for(const [id,b] of R.bookings)shadow.set(id,{json:J(b),slots:slotsOf(b)});
    rebuild();soft();
  },fail));
}

onAuthStateChanged(auth,async u=>{
  if(!u){try{await signInAnonymously(auth)}catch(e){console.error(e);FB.loaded=true;render()}return}
  FB.uid=u.uid;FB.isAdmin=false;
  if(!u.isAnonymous){
    try{FB.isAdmin=(await getDoc(doc(fs,'admins',u.uid))).exists()}catch(e){console.error(e)}
    if(!FB.isAdmin){toast('این حساب دسترسی مدیر ندارد.');await signOut(auth);return}
  }
  shadow.clear();R.bookings=new Map();
  subscribe();render();
});
FB.login=(email,pw)=>signInWithEmailAndPassword(auth,email,pw);
FB.logout=()=>signOut(auth);

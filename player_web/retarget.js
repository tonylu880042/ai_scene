// Retarget Quaternius Universal Animation Library clips (Blender "DEF-*" rig) onto the
// Universal Base Characters rig (UE-style bone names). Both rigs share proportions/rest pose
// closely, so we retarget in world space: B_world(t) = A_world(t) * A_world_rest^-1 * B_world_rest.
import * as THREE from 'three';

const PAIRS = { 'DEF-hips': 'pelvis', 'DEF-spine.001': 'spine_01', 'DEF-spine.002': 'spine_02', 'DEF-spine.003': 'spine_03',
  'DEF-neck': 'neck_01', 'DEF-head': 'Head' };
const LIMB = { shoulder: 'clavicle', upper_arm: 'upperarm', forearm: 'lowerarm', hand: 'hand', thigh: 'thigh', shin: 'calf', foot: 'foot', toe: 'ball' };

export function mapBone(n) {
  if (PAIRS[n]) return PAIRS[n];
  let m = n.match(/^DEF-(shoulder|upper_arm|forearm|hand|thigh|shin|foot|toe)\.(L|R)$/);
  if (m) return `${LIMB[m[1]]}_${m[2].toLowerCase()}`;
  m = n.match(/^DEF-(?:f_)?(index|middle|ring|pinky|thumb)\.(\d\d)\.(L|R)$/);
  if (m) return `${m[1]}_${m[2]}_${m[3].toLowerCase()}`;
  return null;
}

export function retargetClip(srcClip, srcScene, dstScene, fps = 60) {
  srcScene.updateMatrixWorld(true); dstScene.updateMatrixWorld(true);
  const srcBones = new Map(); // dst name -> src bone
  srcScene.traverse(o => {
    const orig = o.userData.name || o.name, t = mapBone(orig);
    if (t) srcBones.set(t, o);
  });
  const order = []; // dst bones in hierarchy order that have a src counterpart
  dstScene.traverse(o => { if (srcBones.has(o.name)) order.push(o); });
  const wq = o => o.getWorldQuaternion(new THREE.Quaternion());
  const restA = new Map(), restB = new Map(), restBLocalPos = new Map();
  for (const b of order) { restA.set(b.name, wq(srcBones.get(b.name))); restB.set(b.name, wq(b)); }
  const parentRestB = new Map(order.map(b => [b.name, wq(b.parent)]));
  const hipsA = srcBones.get('pelvis'), hipsB = order.find(b => b.name === 'pelvis');
  const restPosA = hipsA.position.clone(), restPosB = hipsB.position.clone();
  const hA = hipsA.getWorldPosition(new THREE.Vector3()).y, hB = hipsB.getWorldPosition(new THREE.Vector3()).y;
  const ratio = hB / hA;

  const mixer = new THREE.AnimationMixer(srcScene);
  const act = mixer.clipAction(srcClip); act.play();
  const n = Math.round(srcClip.duration * fps) + 1;
  const times = new Float32Array(n), vals = new Map(order.map(b => [b.name, new Float32Array(n * 4)])), hipPos = new Float32Array(n * 3);
  const tmp = new THREE.Quaternion(), D = new THREE.Quaternion(), computed = new Map();
  for (let i = 0; i < n; i++) {
    const t = Math.min(i / fps, srcClip.duration); times[i] = t;
    mixer.setTime(t); srcScene.updateMatrixWorld(true);
    computed.clear();
    for (const b of order) {
      const wA = wq(srcBones.get(b.name));
      D.copy(wA).multiply(restA.get(b.name).clone().invert());
      const wB = D.clone().multiply(restB.get(b.name));
      const par = computed.get(b.parent.name) || parentRestB.get(b.name);
      computed.set(b.name, wB);
      tmp.copy(par).invert().multiply(wB).normalize();
      tmp.toArray(vals.get(b.name), i * 4);
    }
    const p = hipsA.position.clone().sub(restPosA).multiplyScalar(ratio).add(restPosB);
    p.toArray(hipPos, i * 3);
  }
  mixer.stopAllAction(); mixer.uncacheRoot(srcScene);
  const tracks = order.map(b => new THREE.QuaternionKeyframeTrack(`${b.name}.quaternion`, times, vals.get(b.name)));
  tracks.push(new THREE.VectorKeyframeTrack('pelvis.position', times, hipPos));
  const clip = new THREE.AnimationClip(srcClip.name, srcClip.duration, tracks);
  return clip;
}

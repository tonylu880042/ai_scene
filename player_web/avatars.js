import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import * as SkeletonUtils from 'three/addons/utils/SkeletonUtils.js';
import { retargetClip } from './retarget.js';

const A = 'assets/';
const gltfLoader = new GLTFLoader();
const texLoader = new THREE.TextureLoader();
const load = u => gltfLoader.loadAsync(u);
const srgbTex = u => texLoader.loadAsync(u).then(t => { t.flipY = false; t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4; return t; });

export const CLIP = 'Jog_Fwd_Loop';

export async function loadAvatarAssets(onProgress = () => {}) {
  const anim = await load(A + 'anim/AnimationLibrary_Godot_Standard.gltf');
  const srcClip = anim.animations.find(c => c.name === CLIP);
  const out = { chars: {}, hair: {}, skins: {}, clipSpeed: {}, clips: {} };
  for (const g of ['Male', 'Female']) {
    const gl = await load(`${A}chars/Superhero_${g}_FullBody.gltf`);
    out.chars[g] = gl.scene;
    out.clips[g] = retargetClip(srcClip, anim.scene, gl.scene);
    onProgress(g);
  }
  out.skins = {
    Male: { dark: await srgbTex(A + 'chars/T_Superhero_Male_Dark.png'), light: await srgbTex(A + 'chars/T_Superhero_Male_Light.png') },
    Female: { dark: await srgbTex(A + 'chars/T_Superhero_Female_Dark_BaseColor.png'), light: await srgbTex(A + 'chars/T_Superhero_Female_Light_BaseColor.png') },
  };
  for (const h of ['Hair_Buzzed', 'Hair_SimpleParted', 'Hair_Beard', 'Hair_Long', 'Hair_Buns', 'Hair_BuzzedFemale']) {
    out.hair[h] = (await load(`${A}chars/${h}.gltf`)).scene;
  }
  // natural ground speed of the retargeted run clip (m/s), so that cadence follows ground speed (no foot sliding)
  out.clipSpeed = measureClipSpeed(out.chars.Male, out.clips.Male);
  out.clipDuration = out.clips.Male.duration;
  return out;
}

// Stance-foot speed over one cycle = ground speed the clip "wants" at timeScale 1.
export function measureClipSpeed(scene, clip) {
  const m = SkeletonUtils.clone(scene);
  const mixer = new THREE.AnimationMixer(m); mixer.clipAction(clip).play();
  const fl = m.getObjectByName('ball_l'), fr = m.getObjectByName('ball_r');
  const N = 240, dt = clip.duration / N, v = new THREE.Vector3();
  const z = [], y = [];
  for (let i = 0; i <= N; i++) {
    mixer.setTime(i * dt); m.updateMatrixWorld(true);
    fl.getWorldPosition(v); const zl = v.z, yl = v.y; fr.getWorldPosition(v);
    z.push([zl, v.z]); y.push([yl, v.y]);
  }
  const sp = [];
  for (let i = 0; i < N; i++) {
    const k = y[i][0] < y[i][1] ? 0 : 1; // lower foot = stance foot
    if (Math.min(y[i][0], y[i][1]) < 0.06 || true) sp.push(-(z[i + 1][k] - z[i][k]) / dt);
  }
  sp.sort((a, b) => a - b);
  return sp[Math.floor(sp.length / 2)];
}

const OUTFIT_GLSL_V = `varying vec3 vRest;`;
const OUTFIT_GLSL_F = `
varying vec3 vRest; uniform vec3 uShirt; uniform vec3 uShorts; uniform vec3 uShoe; uniform vec3 uSock; uniform float uTop; uniform float uHem;
`;

function makeBodyMaterial(base, skinTex, o) {
  const m = base.clone();
  m.map = skinTex; m.metalness = 0; m.roughness = 1;
  const uniforms = { uShirt: { value: new THREE.Color(o.shirt) }, uShorts: { value: new THREE.Color(o.shorts) },
    uShoe: { value: new THREE.Color(o.shoes) }, uSock: { value: new THREE.Color(o.socks || '#f2f2f2') },
    uTop: { value: o.female ? 1.0 : 0.0 }, uHem: { value: o.female ? 1.18 : 1.04 } };
  m.onBeforeCompile = sh => {
    Object.assign(sh.uniforms, uniforms);
    sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\n' + OUTFIT_GLSL_V)
      .replace('#include <begin_vertex>', '#include <begin_vertex>\nvRest = position;');
    sh.fragmentShader = sh.fragmentShader.replace('#include <common>', '#include <common>\n' + OUTFIT_GLSL_F)
      .replace('#include <map_fragment>', `#include <map_fragment>
      {
        vec3 p = vRest; float ax = abs(p.x);
        float lum = dot(diffuseColor.rgb, vec3(0.3, 0.59, 0.11));
        float e = 0.012;
        // short-sleeve top: torso + sleeves (arms are held horizontally in the rest pose)
        float torso = smoothstep(uHem - e, uHem + e, p.y) * (1.0 - smoothstep(0.205, 0.205 + e, ax)) * (1.0 - smoothstep(1.49, 1.49 + e, p.y));
        float sleeve = smoothstep(1.36, 1.36 + e, p.y) * (1.0 - smoothstep(1.56, 1.56 + e, p.y)) * smoothstep(0.19, 0.19 + e, ax) * (1.0 - smoothstep(0.37, 0.37 + e, ax));
        float neck = (1.0 - smoothstep(0.085, 0.095, ax)) * smoothstep(1.455, 1.47, p.y);
        float top = clamp(torso + sleeve, 0.0, 1.0) * (1.0 - neck);
        // shorts
        float shorts = smoothstep(0.68, 0.68 + e, p.y) * (1.0 - smoothstep(1.04, 1.04 + e, p.y)) * (1.0 - smoothstep(0.30, 0.30 + e, ax));
        // shoes / socks
        float shoe = 1.0 - smoothstep(0.085, 0.085 + e, p.y);
        float sock = (1.0 - smoothstep(0.20, 0.20 + e, p.y)) * (1.0 - shoe);
        vec3 shade = vec3(0.78 + 0.5 * lum);
        vec3 c = diffuseColor.rgb;
        c = mix(c, uSock * shade, sock * 0.95);
        c = mix(c, uShorts * shade, shorts);
        c = mix(c, uShirt * shade, top);
        c = mix(c, uShoe * (0.7 + 0.6 * lum), shoe);
        diffuseColor.rgb = c;
      }`);
  };
  m.customProgramCacheKey = () => 'body' + m.uuid;
  m.needsUpdate = true;
  return m;
}

export function createAvatar(assets, spec) {
  const g = spec.gender;
  const root = new THREE.Group();
  const model = SkeletonUtils.clone(assets.chars[g]);
  model.traverse(o => {
    if (o.isMesh) {
      o.frustumCulled = false; o.castShadow = true; o.receiveShadow = false;
      if (o.material && o.material.name.startsWith('MI_Superhero')) {
        o.material = makeBodyMaterial(o.material, assets.skins[g][spec.skin], { shirt: spec.shirt, shorts: spec.shorts, shoes: spec.shoes, socks: spec.socks, female: g === 'Female' });
      } else if (o.material) {
        o.material = o.material.clone();
        if (o.material.name.startsWith('MI_Hair') && spec.hairColor) o.material.color.set(spec.hairColor);
      }
    }
  });
  model.updateMatrixWorld(true);
  const head = model.getObjectByName('Head');
  for (const h of spec.hair || []) {
    const hs = assets.hair[h].clone(true);
    hs.traverse(o => { if (o.isMesh) { o.material = o.material.clone(); if (spec.hairColor) o.material.color.set(spec.hairColor); o.castShadow = true; o.frustumCulled = false; } });
    model.add(hs); model.updateMatrixWorld(true);
    head.attach(hs);
  }
  root.add(model);
  root.scale.setScalar(spec.scale || 1);
  const mixer = new THREE.AnimationMixer(model);
  const action = mixer.clipAction(assets.clips[g]); action.play();
  return { root, mixer, action, duration: assets.clips[g].duration, model };
}

// ---- Microsoft Rocketbox (MIT) realistic sports avatars, converted FBX -> GLB by tools in fetch_assets.py.
// Each GLB carries an in-place "run" clip (Rocketbox m/f_run_neutral; root drift removed at conversion).
export const ROCKETBOX = {
  models: ['Sports_Female_02', 'Sports_Male_04', 'Female_Party_02', 'Sports_Male_02'],
  // ground speed of the original root motion (m/s) per clip; filled from assets/rocketbox/speeds.json
};

export async function loadRocketboxAssets() {
  const speeds = await fetch(A + 'rocketbox/speeds.json').then(r => r.json());
  const out = { rb: {}, clipSpeedOf: {} };
  for (const m of ROCKETBOX.models) {
    const gl = await load(`${A}rocketbox/${m}.glb`);
    gl.scene.traverse(o => { if (o.isMesh) { o.castShadow = true; o.frustumCulled = false;
      const mat = o.material; if (mat && mat.map) { mat.map.anisotropy = 4; } if (mat) { mat.metalness = 0; mat.roughness = 0.8; } } });
    out.rb[m] = { scene: gl.scene, clip: gl.animations.find(c => c.name === 'run') || gl.animations[0] };
    out.clipSpeedOf[m] = speeds[m];
  }
  return out;
}

export function createRocketboxAvatar(assets, spec) {
  const src = assets.rb[spec.model];
  const root = new THREE.Group();
  const model = SkeletonUtils.clone(src.scene);
  model.traverse(o => { if (o.isMesh) { o.material = o.material.clone(); o.castShadow = true; o.frustumCulled = false; } });
  root.add(model);
  root.scale.setScalar(spec.scale || 1);
  const mixer = new THREE.AnimationMixer(model);
  const action = mixer.clipAction(src.clip); action.play();
  return { root, mixer, action, duration: src.clip.duration, model, clipSpeed: assets.clipSpeedOf[spec.model] * (spec.scale || 1) };
}

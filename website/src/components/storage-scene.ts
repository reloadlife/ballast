import * as THREE from "three";

export function createStorageScene(host: HTMLElement) {
  const renderer = new THREE.WebGLRenderer({
    alpha: true,
    antialias: true,
    powerPreference: "low-power",
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.5));
  renderer.setClearColor(0x000000, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.55;
  renderer.domElement.setAttribute("aria-hidden", "true");
  host.appendChild(renderer.domElement);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(34, 1, 0.1, 40);
  camera.position.set(0, 0, 10.8);
  const root = new THREE.Group();
  root.rotation.set(-0.72, -0.33, -0.33);
  scene.add(root);
  scene.add(new THREE.AmbientLight(0xffffff, 2));
  const key = new THREE.DirectionalLight(0xffffff, 5);
  key.position.set(-3, 6, 8);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xffe1bd, 2);
  fill.position.set(4, -2, 3);
  scene.add(fill);
  const edge = new THREE.DirectionalLight(0xffffff, 3);
  edge.position.set(0, 3, -5);
  scene.add(edge);
  const materials = [0xe9e7e3, 0xddd9d1, 0xff682d].map(
    (color) =>
      new THREE.MeshStandardMaterial({
        color,
        roughness: 0.28,
        metalness: 0.22,
      }),
  );
  const parts: {
    mesh: THREE.Mesh;
    layer: number;
    orange: boolean;
    angle: number;
  }[] = [];
  const geometries: THREE.BufferGeometry[] = [];
  const slices = [0.43, 0.33, 0.24];
  for (let layer = 0; layer < 3; layer++) {
    let start = 0;
    slices.forEach((fraction, index) => {
      const end = start + fraction * Math.PI * 2;
      const gap = 0.025;
      const shape = new THREE.Shape();
      shape.absarc(0, 0, 2.03, start + gap, end - gap, false);
      shape.absarc(0, 0, 0.96, end - gap, start + gap, true);
      shape.closePath();
      const geometry = new THREE.ExtrudeGeometry(shape, {
        depth: 0.32,
        bevelEnabled: true,
        bevelSegments: 4,
        steps: 1,
        bevelSize: 0.075,
        bevelThickness: 0.075,
        curveSegments: 48,
      });
      geometries.push(geometry);
      const mesh = new THREE.Mesh(geometry, materials[index]);
      mesh.position.z = (layer - 1) * 0.49;
      root.add(mesh);
      parts.push({
        mesh,
        layer,
        orange: index === 2,
        angle: (start + end) / 2,
      });
      start = end;
    });
  }
  let progress = 0,
    pointerX = 0,
    pointerY = 0,
    disposed = false;
  const render = () => {
    if (disposed) return;
    root.rotation.y = -0.33 + pointerX * 0.13;
    root.rotation.x = -0.72 + pointerY * 0.1;
    for (const part of parts) {
      const offset = part.orange ? progress * 0.65 : 0;
      part.mesh.position.set(
        Math.cos(part.angle) * offset,
        Math.sin(part.angle) * offset,
        (part.layer - 1) * (0.49 + progress * 0.36) +
          (part.orange ? progress * 0.25 : 0),
      );
    }
    renderer.render(scene, camera);
  };
  const resize = new ResizeObserver(() => {
    const { width, height } = host.getBoundingClientRect();
    renderer.setSize(width, height, false);
    camera.aspect = width / Math.max(height, 1);
    camera.updateProjectionMatrix();
    render();
  });
  resize.observe(host);
  render();
  return {
    update(value: number) {
      progress = value;
      render();
    },
    pointer(x: number, y: number) {
      pointerX = x;
      pointerY = y;
      render();
    },
    dispose() {
      disposed = true;
      resize.disconnect();
      geometries.forEach((g) => g.dispose());
      materials.forEach((m) => m.dispose());
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}

/**
 * ASCII Galaxy Animation
 * Mimics the LEGO Milky Way galaxy shape
 */

// Varied characters for visual interest - jitter breaks up banding
const ASCII_CHARS = ' .·:;+*#%@';

class Galaxy {
    constructor(container) {
        this.container = container;
        this.cols = 0;
        this.rows = 0;
        this.time = 0;
        this.charWidth = 6;
        this.charHeight = 10;
        this.init();
    }

    init() {
        this.resize();
        window.addEventListener('resize', () => this.resize());
        this.animateLogo();
        this.animate();
    }

    resize() {
        this.cols = Math.floor(window.innerWidth / this.charWidth) + 1;
        this.rows = Math.floor(window.innerHeight / this.charHeight) + 1;
        this.centerX = this.cols / 2;
        this.centerY = this.rows * 0.40;
    }

    // Slower, smoother shimmer for logo
    animateLogo() {
        const logoEl = document.getElementById('logo');
        const text = 'kira';
        let frame = 0;
        let nextBlinkTime = [3000, 5000, 7000, 9000]; // Stagger initial blinks
        let blinkStart = [0, 0, 0, 0];
        
        const updateLogo = () => {
            frame++;
            const now = performance.now();
            let html = '';
            
            for (let i = 0; i < text.length; i++) {
                // Subtle ambient shimmer
                const wave = Math.sin(frame * 0.015 + i * 0.8);
                const wave2 = Math.sin(frame * 0.025 + i * 1.2);
                
                // Check if it's time to start a blink
                if (blinkStart[i] === 0 && now > nextBlinkTime[i]) {
                    blinkStart[i] = now;
                    // Schedule next blink 5-12 seconds from now
                    nextBlinkTime[i] = now + 5000 + Math.random() * 7000;
                }
                
                // Handle blink animation (very fast - 80ms total)
                let blinkAlpha = 0;
                if (blinkStart[i] > 0) {
                    const blinkAge = now - blinkStart[i];
                    if (blinkAge < 40) {
                        // Ramp up (40ms)
                        blinkAlpha = blinkAge / 40;
                    } else if (blinkAge < 80) {
                        // Ramp down (40ms)
                        blinkAlpha = 1 - (blinkAge - 40) / 40;
                    } else {
                        // Blink done
                        blinkStart[i] = 0;
                    }
                }
                
                let alpha;
                if (blinkAlpha > 0) {
                    alpha = 0.4 + blinkAlpha * 0.6; // Flash to full brightness
                } else {
                    alpha = 0.35 + wave * 0.12 + wave2 * 0.08;
                }
                
                const color = `rgba(255,255,255,${alpha.toFixed(2)})`;
                html += `<span style="color:${color}">${text[i]}</span>`;
            }
            logoEl.innerHTML = html;
            requestAnimationFrame(updateLogo);
        };
        updateLogo();
    }

    hslToHex(h, s, l) {
        s /= 100;
        l /= 100;
        const a = s * Math.min(l, 1 - l);
        const f = n => {
            const k = (n + h / 30) % 12;
            const color = l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1);
            return Math.round(255 * color).toString(16).padStart(2, '0');
        };
        return `#${f(0)}${f(8)}${f(4)}`;
    }

    // Check if point is in an ellipse, return 0-1 intensity (1 at center, 0 at edge)
    ellipseIntensity(x, y, cx, cy, rx, ry, rotation = 0) {
        const dx = x - cx;
        const dy = y - cy;
        const cos = Math.cos(rotation);
        const sin = Math.sin(rotation);
        const rotX = dx * cos + dy * sin;
        const rotY = -dx * sin + dy * cos;
        const dist = Math.sqrt((rotX * rotX) / (rx * rx) + (rotY * rotY) / (ry * ry));
        if (dist > 1) return 0;
        return 1 - dist;
    }
    
    // Very pointy arm shape - tapers sharply toward the end
    armIntensity(x, y, cx, cy, length, baseWidth, rotation) {
        const dx = x - cx;
        const dy = y - cy;
        const cos = Math.cos(rotation);
        const sin = Math.sin(rotation);
        // Rotate point into arm's local space
        const localX = dx * cos + dy * sin;   // along the arm
        const localY = -dx * sin + dy * cos;  // perpendicular
        
        // Arm goes from 0 to length in localX
        if (localX < -length * 0.05 || localX > length) return 0;
        
        // Width tapers sharply: full width at base, very pointy at end
        const t = Math.max(0, localX) / length; // 0 at base, 1 at tip
        const widthAtPoint = baseWidth * Math.pow(1 - t, 1.5); // Sharp taper using power curve
        
        const perpDist = Math.abs(localY);
        if (perpDist > widthAtPoint) return 0;
        
        // Intensity falls off from center and toward tip
        const perpIntensity = 1 - (perpDist / widthAtPoint);
        const lengthIntensity = 1 - t * 0.4; // Dimmer toward tip
        return perpIntensity * lengthIntensity;
    }
    
    // Hash-based noise - no patterns
    noise(x, y, seed = 0) {
        // Use integer coordinates for hashing
        const ix = Math.floor(x * 100 + seed);
        const iy = Math.floor(y * 100 + seed * 7);
        // Multiple prime-based hashing to break patterns
        let h = ix * 374761393 + iy * 668265263 + seed * 1013904223;
        h = (h ^ (h >> 13)) * 1274126177;
        h = h ^ (h >> 16);
        return (h & 0x7fffffff) / 0x7fffffff;
    }
    
    // Animated noise for dynamic scatter
    animatedNoise(x, y, time) {
        const n1 = this.noise(x, y, 0);
        const n2 = this.noise(x, y, 999);
        // Smooth blend over time
        const blend = Math.sin(time * 0.6 + x * 0.5 + y * 0.5) * 0.5 + 0.5;
        return n1 * blend + n2 * (1 - blend);
    }

    // LEGO Milky Way - using screen percentages for sizing
    getGalaxyDensity(col, row) {
        // Convert to percentage-based coordinates (-50 to 50 for x, scaled for y)
        const x = ((col / this.cols) - 0.5) * 100;  // -50 to 50
        const y = ((row / this.rows) - 0.40) * 100; // centered at 40% height
        
        const coreDist = Math.sqrt(x * x + y * y);
        
        // === 1. CIRCULAR CORE (white/orange/red) ===
        const coreIntensity = this.ellipseIntensity(x, y, 0, 0, 7, 5, 0);
        if (coreIntensity > 0) {
            return { density: 0.6 + coreIntensity * 0.4, component: 'core', coreDist };
        }
        
        // === 2. MAIN DISC around core (pink/purple) ===
        // Tiny gap: disc inner edge starts just past core
        const discIntensity = this.ellipseIntensity(x, y, 0, 0, 28, 10, -0.25);
        if (discIntensity > 0 && discIntensity < 0.72) { // Small inner cutout
            return { density: 0.3 + discIntensity * 0.5, component: 'disc', coreDist };
        }
        
        // === 3. BOTTOM ARM (blue, larger, pointy) - starts from disc edge ===
        const bottomArmIntensity = this.armIntensity(x, y, 8, 4, 45, 8, 0.55);
        if (bottomArmIntensity > 0) {
            return { density: 0.25 + bottomArmIntensity * 0.5, component: 'arm-bottom', coreDist };
        }
        
        // === 4. TOP ARM (blue, smaller, pointy) ===
        const topArmIntensity = this.armIntensity(x, y, -12, -5, 22, 4, Math.PI + 0.5);
        if (topArmIntensity > 0) {
            return { density: 0.2 + topArmIntensity * 0.45, component: 'arm-top', coreDist };
        }
        
        // === 5. LEFT ARM (purple/blue, small, pointy) ===
        const leftArmIntensity = this.armIntensity(x, y, -20, 1, 22, 4, Math.PI - 0.1);
        if (leftArmIntensity > 0) {
            return { density: 0.2 + leftArmIntensity * 0.4, component: 'arm-left', coreDist };
        }
        
        // === 6. RIGHT ARM (purple/blue, small, pointy) ===
        const rightArmIntensity = this.armIntensity(x, y, 24, -2, 20, 3.5, 0.05);
        if (rightArmIntensity > 0) {
            return { density: 0.2 + rightArmIntensity * 0.4, component: 'arm-right', coreDist };
        }
        
        // === 7. DYNAMIC SCATTER/LEAK - animated particles ===
        const n = this.animatedNoise(x * 0.25, y * 0.35, this.time);
        const n2 = this.noise(x * 0.4 + 50, y * 0.4 + 50, 123);
        
        // Scatter around disc
        const discProximity = this.ellipseIntensity(x, y, 0, 0, 36, 14, -0.25);
        if (discProximity > 0 && n > 0.72) {
            const scatterIntensity = discProximity * (n - 0.72) * 3.5;
            if (scatterIntensity > 0.06) {
                const scatterType = n2 > 0.6 ? 'scatter-blue' : n2 > 0.3 ? 'scatter-purple' : 'scatter-pink';
                return { density: 0.15 + scatterIntensity * 0.3, component: scatterType, coreDist };
            }
        }
        
        // Scatter around arms (with larger detection zones)
        const armProximity = Math.max(
            this.armIntensity(x, y, 8, 4, 52, 12, 0.55),
            this.armIntensity(x, y, -12, -5, 28, 7, Math.PI + 0.5),
            this.armIntensity(x, y, -20, 1, 28, 7, Math.PI - 0.1),
            this.armIntensity(x, y, 24, -2, 26, 6, 0.05)
        );
        if (armProximity > 0 && n > 0.68) {
            const scatterIntensity = armProximity * (n - 0.68) * 3;
            if (scatterIntensity > 0.05) {
                const scatterType = n2 > 0.5 ? 'scatter-blue' : 'scatter-purple';
                return { density: 0.12 + scatterIntensity * 0.28, component: scatterType, coreDist };
            }
        }
        
        return { density: 0, component: 'space', coreDist };
    }

    getGalaxyData(col, row) {
        const { density, component, coreDist } = this.getGalaxyDensity(col, row);
        
        if (density < 0.02) {
            return this.getDeepSpaceData(col, row);
        }
        
        // Smooth continuous shimmer (no discrete jumps)
        const flowPhase = col * 0.04 + row * 0.04 + this.time * 0.4;
        const shimmer = Math.sin(flowPhase) * 0.08 + Math.sin(flowPhase * 1.3 + this.time * 0.25) * 0.06;
        
        let animatedDensity = density * (0.92 + shimmer);
        
        // Smooth sparkles using continuous sine waves instead of floor()
        const sparklePhase = col * 0.7 + row * 0.9 + this.time * 2;
        const sparkle = (Math.sin(sparklePhase) + Math.sin(sparklePhase * 0.7 + 1.3)) * 0.5;
        if (sparkle > 0.85 && density > 0.3) {
            animatedDensity = Math.min(1, animatedDensity + (sparkle - 0.85) * 1.5);
        }
        
        const color = this.getComponentColor(component, density, coreDist);
        
        return { density: animatedDensity, color };
    }

    getComponentColor(component, density, coreDist) {
        const flow = this.time * 0.25;
        let hue, sat, light;
        
        if (component === 'core') {
            // Core: white center → orange → red at edges
            const t = Math.min(1, coreDist / 10);
            if (t < 0.4) {
                // Bright white/cream center
                hue = 45;
                sat = 20;
                light = 90 + density * 8;
            } else if (t < 0.7) {
                // Orange
                hue = 30;
                sat = 80;
                light = 65 + density * 15;
            } else {
                // Red/coral edge
                hue = 10;
                sat = 85;
                light = 50 + density * 20;
            }
        } else if (component === 'disc') {
            // Disc: pink/magenta/purple
            hue = 320 + Math.sin(flow) * 12;
            sat = 70;
            light = 45 + density * 30;
        } else if (component === 'arm-bottom' || component === 'arm-top') {
            // Main arms: blue
            hue = 215 + Math.sin(flow * 0.8) * 12;
            sat = 75;
            light = 40 + density * 35;
        } else if (component === 'arm-left' || component === 'arm-right') {
            // Side arms: purple/violet
            hue = 265 + Math.sin(flow * 0.7) * 10;
            sat = 65;
            light = 35 + density * 35;
        } else if (component === 'scatter-blue') {
            // Scattered blue particles
            hue = 210 + Math.sin(flow) * 15;
            sat = 60;
            light = 35 + density * 40;
        } else if (component === 'scatter-purple') {
            // Scattered purple particles
            hue = 270 + Math.sin(flow * 0.9) * 12;
            sat = 55;
            light = 32 + density * 38;
        } else if (component === 'scatter-pink') {
            // Scattered pink particles
            hue = 330 + Math.sin(flow * 0.8) * 10;
            sat = 55;
            light = 38 + density * 35;
        } else {
            hue = 250;
            sat = 50;
            light = 25;
        }
        
        return this.hslToHex(hue, Math.min(100, sat), Math.max(10, Math.min(95, light)));
    }

    getDeepSpaceData(col, row) {
        const hash = Math.sin(col * 12.9898 + row * 78.233) * 43758.5453;
        const rand = hash - Math.floor(hash);
        
        // Stars
        if (rand > 0.991) {
            const twinkle = Math.sin(this.time * (1 + rand * 1.5) + rand * 40) * 0.35 + 0.65;
            const starHue = 200 + rand * 60;
            return { 
                density: 0.08 + twinkle * 0.18, 
                color: this.hslToHex(starHue, 20 + rand * 25, 45 + twinkle * 40) 
            };
        }
        
        // Faint nebula
        if (rand > 0.965) {
            const hue = 240 + Math.sin(col * 0.03 + row * 0.025) * 40;
            return { 
                density: 0.04 + Math.sin(this.time * 0.5 + rand * 10) * 0.015, 
                color: this.hslToHex(hue, 30, 7 + rand * 5) 
            };
        }
        
        return { density: 0.015, color: this.hslToHex(250, 20, 4) };
    }

    getChar(density, col, row) {
        // Use the same noise function for consistent randomness without patterns
        const jitter = this.noise(col, row, 12345) * 0.22 - 0.11;
        const jitteredDensity = Math.max(0, Math.min(1, density + jitter));
        const index = Math.floor(jitteredDensity * (ASCII_CHARS.length - 1));
        return ASCII_CHARS[Math.min(Math.max(index, 0), ASCII_CHARS.length - 1)];
    }

    render() {
        let html = '';
        for (let row = 0; row < this.rows; row++) {
            for (let col = 0; col < this.cols; col++) {
                const { density, color } = this.getGalaxyData(col, row);
                html += `<span style="color:${color}">${this.getChar(density, col, row)}</span>`;
            }
            html += '\n';
        }
        this.container.innerHTML = html;
    }

    animate() {
        this.time += 0.016;
        this.render();
        requestAnimationFrame(() => this.animate());
    }
}

document.addEventListener('DOMContentLoaded', () => {
    new Galaxy(document.getElementById('galaxy'));
});

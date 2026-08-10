import asyncio
import websockets
import json
import base64
import cv2
import numpy as np
import open3d as o3d

# 1. Initialize Open3D Visualizer Window
vis = o3d.visualization.Visualizer()
vis.create_window(window_name="iPhone Live 3D Map", width=1280, height=720)

global_pcd = o3d.geometry.PointCloud()
added_to_vis = False

async def handle_mapping_client(websocket):
    global global_pcd, added_to_vis
    print("📱 iPhone Connected to 3D Mapper Test!")
    
    try:
        async for message in websocket:
            data = json.loads(message)
            
            # Gracefully handle control-only messages (e.g., start/stop recording triggers)
            if "action" in data and not all(k in data for k in ("image", "depth", "intrinsics", "transform")):
                print(f"📥 Control action received: {data['action']}")
                continue
            
            # Ensure all required mapping keys exist for frame data
            if not all(k in data for k in ("image", "depth", "intrinsics", "transform")):
                print("⚠️ Missing required mapping payloads (image/depth/intrinsics/transform)")
                continue
            
            # 2. Decode Image
            image_bytes = base64.b64decode(data["image"])
            frame_raw = cv2.imdecode(np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR)
            if frame_raw is None:
                continue
            frame_portrait = cv2.rotate(frame_raw, cv2.ROTATE_90_CLOCKWISE)
            h, w, _ = frame_portrait.shape
            
            # 3. Decode Depth Map (ARKit standard scene depth resolution is 256x192)
            depth_bytes = base64.b64decode(data["depth"])
            depth_arr = np.frombuffer(depth_bytes, dtype=np.float32)
            
            # Ensure buffer size matches expected dimensions before reshaping
            if depth_arr.size != 192 * 256:
                continue
                
            depth_map_raw = depth_arr.reshape((192, 256)) 
            depth_portrait = cv2.rotate(depth_map_raw, cv2.ROTATE_90_CLOCKWISE)
            depth_map = cv2.resize(depth_portrait, (w, h), interpolation=cv2.INTER_LINEAR)
            
            # 4. Extract Intrinsics (3x3) and Transform (4x4 Pose)
            K = np.array(data["intrinsics"]).reshape(3, 3)
            T_cam_to_world = np.array(data["transform"]).reshape(4, 4)
            
            fx, fy = K[0, 0], K[1, 1]
            cx, cy = K[0, 2], K[1, 2]
            
            # 5. Back-project pixels to 3D Camera coordinates
            u_coords, v_coords = np.meshgrid(np.arange(w), np.arange(h))
            valid_mask = (depth_map > 0.1) & (depth_map < 4.0) & (~np.isnan(depth_map))
            
            Z = depth_map[valid_mask]
            u = u_coords[valid_mask]
            v = v_coords[valid_mask]
            
            X = (u - cx) * Z / fx
            Y = (v - cy) * Z / fy
            points_cam = np.vstack((X, Y, Z, np.ones_like(Z))) # (4, N)
            
            # 6. Transform to World coordinates using ARKit pose
            points_world = np.dot(T_cam_to_world, points_cam)[:3, :].T # (N, 3)
            
            # 7. Grab matching colors
            rgb_image = cv2.cvtColor(frame_portrait, cv2.COLOR_BGR2RGB)
            colors = rgb_image[valid_mask].astype(np.float64) / 255.0
            
            # 8. Build Open3D Point Cloud for this frame
            pcd = o3d.geometry.PointCloud()
            pcd.points = o3d.utility.Vector3dVector(points_world)
            pcd.colors = o3d.utility.Vector3dVector(colors)
            
            # Downsample to keep memory clean
            pcd = pcd.voxel_down_sample(voxel_size=0.02)
            
            # Accumulate into global map
            global_pcd += pcd
            global_pcd = global_pcd.voxel_down_sample(voxel_size=0.015)
            
            # 9. Dynamically update the Open3D visualizer window
            if not added_to_vis:
                vis.add_geometry(global_pcd)
                added_to_vis = True
            else:
                vis.update_geometry(global_pcd)
                
            vis.poll_events()
            vis.update_renderer()
            
    except websockets.exceptions.ConnectionClosed:
        print("📱 iPhone disconnected from 3D mapper test.")

async def main():
    server = await websockets.serve(handle_mapping_client, "0.0.0.0", 8766, max_size=None)
    print("🚀 Standalone 3D Mapping Server running on ws://0.0.0.0:8766")
    await server.wait_closed()

if __name__ == "__main__":
    asyncio.run(main())
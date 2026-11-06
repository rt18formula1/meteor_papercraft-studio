import AppKit
import ModelIO
import simd
import UniformTypeIdentifiers

private struct MeshPoint3 {
    var x: Double; var y: Double; var z: Double
    static func -(a: MeshPoint3, b: MeshPoint3) -> MeshPoint3 { MeshPoint3(x:a.x-b.x,y:a.y-b.y,z:a.z-b.z) }
    var length: Double { sqrt(x*x+y*y+z*z) }
}

private struct MeshEdge: Hashable {
    let a: Int; let b: Int
    init(_ x: Int, _ y: Int) { a=min(x,y); b=max(x,y) }
}

struct MeshNetFacet {
    let vertices: [Int]
    let points: [Point2]
    let planarEdges: [Bool]
    let net: Int
}

struct MeshNetModel {
    let facets: [MeshNetFacet]
    let pageCount: Int
    let cutEdges: Int
    let foldedEdges: Int
}

enum MeshNetError: LocalizedError {
    case unsupported(String)
    case empty
    case tooManyFaces(Int)
    var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .empty: return "この3Dファイルから三角形メッシュを読み取れませんでした。USDZ、OBJ、STL形式を選んでください。"
        case .tooManyFaces(let count): return "このモデルは \(count) 面あります。印刷用の細かさを超えるため、この段階では展開できません。先に3Dソフトでポリゴン数を減らしてください。"
        }
    }
}

enum MeshNetBuilder {
    private struct Triangle { let ids: [Int] }
    private struct PositionKey: Hashable { let x:Int64; let y:Int64; let z:Int64 }

    static func build(from url: URL, targetWidthMM: Double) throws -> MeshNetModel {
        let asset: MDLAsset
        asset = MDLAsset(url:url)

        var positions: [MeshPoint3] = []
        var positionMap: [PositionKey:Int] = [:]
        var triangles: [Triangle] = []
        func addMesh(_ mesh: MDLMesh, transform: simd_float4x4) {
            guard let source = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3), source.stride > 0 else { return }
            var localToGlobal: [Int] = []; localToGlobal.reserveCapacity(mesh.vertexCount)
            for i in 0..<mesh.vertexCount {
                let p = source.dataStart.advanced(by:i*source.stride).assumingMemoryBound(to:Float.self)
                let world = simd_mul(transform, SIMD4<Float>(p[0],p[1],p[2],1))
                let point = MeshPoint3(x:Double(world.x),y:Double(world.y),z:Double(world.z))
                let key = PositionKey(x:Int64((point.x*1_000_000).rounded()),y:Int64((point.y*1_000_000).rounded()),z:Int64((point.z*1_000_000).rounded()))
                if let existing = positionMap[key] { localToGlobal.append(existing) }
                else { let index=positions.count; positions.append(point); positionMap[key]=index; localToGlobal.append(index) }
            }
            let submeshes = mesh.submeshes?.compactMap { $0 as? MDLSubmesh } ?? []
            for original in submeshes {
                guard original.geometryType == .triangles || original.geometryType == .triangleStrips || original.geometryType == .quads else { continue }
                guard let submesh = MDLSubmesh(mdlSubmesh:original,indexType:.uInt32,geometryType:.triangles) else { continue }
                let map = submesh.indexBuffer(asIndexType:.uInt32).map()
                let indices = map.bytes.assumingMemoryBound(to:UInt32.self)
                let count = submesh.indexCount
                if count < 3 { continue }
                for start in stride(from:0,to:count-2,by:3) {
                    let a=Int(indices[start]), b=Int(indices[start+1]), c=Int(indices[start+2])
                    guard a<localToGlobal.count,b<localToGlobal.count,c<localToGlobal.count else { continue }
                    let ids=[localToGlobal[a],localToGlobal[b],localToGlobal[c]]
                    let u=positions[ids[1]]-positions[ids[0]], v=positions[ids[2]]-positions[ids[0]]
                    let crossX=u.y*v.z-u.z*v.y, crossY=u.z*v.x-u.x*v.z, crossZ=u.x*v.y-u.y*v.x
                    let area2=sqrt(crossX*crossX+crossY*crossY+crossZ*crossZ)
                    if Set(ids).count == 3 && area2 > 1e-12 { triangles.append(Triangle(ids:ids)) }
                }
            }
        }
        func worldMatrix(_ object:MDLObject) -> simd_float4x4 {
            var chain:[MDLObject]=[],cursor:MDLObject?=object
            while let node=cursor { chain.append(node);cursor=node.parent }
            return chain.reversed().reduce(matrix_identity_float4x4) { matrix,node in
                simd_mul(matrix,node.transform?.matrix ?? matrix_identity_float4x4)
            }
        }
        for object in asset.childObjects(of:MDLMesh.self) {
            guard let mesh=object as? MDLMesh else { continue }
            addMesh(mesh,transform:worldMatrix(object))
        }
        guard !triangles.isEmpty, !positions.isEmpty else { throw MeshNetError.empty }
        guard triangles.count <= 2500 else { throw MeshNetError.tooManyFaces(triangles.count) }

        let maxX=positions.map(\.x).max()!, minX=positions.map(\.x).min()!, maxY=positions.map(\.y).max()!, minY=positions.map(\.y).min()!, maxZ=positions.map(\.z).max()!, minZ=positions.map(\.z).min()!
        let longest=max(maxX-minX,max(maxY-minY,maxZ-minZ))
        guard longest > 1e-9 else { throw MeshNetError.empty }
        let scale=targetWidthMM/longest
        var edgeFaces: [MeshEdge:[Int]] = [:]
        for (i,t) in triangles.enumerated() { for k in 0..<3 { edgeFaces[MeshEdge(t.ids[k],t.ids[(k+1)%3]),default:[]].append(i) } }
        func normal(_ t:Triangle)->MeshPoint3 {
            let a=positions[t.ids[0]],u=positions[t.ids[1]]-a,v=positions[t.ids[2]]-a
            let nx=u.y*v.z-u.z*v.y,ny=u.z*v.x-u.x*v.z,nz=u.x*v.y-u.y*v.x
            let magnitude=max(1e-12,sqrt(nx*nx+ny*ny+nz*nz))
            return MeshPoint3(x:nx/magnitude,y:ny/magnitude,z:nz/magnitude)
        }
        let normals=triangles.map(normal)
        var planarEdges=Set<MeshEdge>()
        for (edge,faces) in edgeFaces where faces.count==2 {
            let a=normals[faces[0]],b=normals[faces[1]]
            if abs(a.x*b.x+a.y*b.y+a.z*b.z)>0.9995 { planarEdges.insert(edge) }
        }
        var neighbors=Array(repeating:[Int](),count:triangles.count)
        for faces in edgeFaces.values where faces.count > 1 {
            for a in faces { for b in faces where a != b { neighbors[a].append(b) } }
        }
        // Grow each net across coplanar edges first. This keeps flat regions together
        // and leaves sharp feature lines as natural seams before overlap avoidance
        // introduces additional cuts. The tie-breaker makes the result deterministic.
        func sharedEdge(_ a:Int,_ b:Int)->MeshEdge? {
            let shared=triangles[a].ids.filter { triangles[b].ids.contains($0) }
            return shared.count == 2 ? MeshEdge(shared[0],shared[1]) : nil
        }
        for index in neighbors.indices {
            neighbors[index] = Array(Set(neighbors[index])).sorted { left, right in
                let leftEdge=sharedEdge(index,left), rightEdge=sharedEdge(index,right)
                let leftPlanar=leftEdge.map { planarEdges.contains($0) } ?? false
                let rightPlanar=rightEdge.map { planarEdges.contains($0) } ?? false
                if leftPlanar != rightPlanar { return leftPlanar && !rightPlanar }
                let leftLength=leftEdge.map { (positions[$0.a]-positions[$0.b]).length } ?? 0
                let rightLength=rightEdge.map { (positions[$0.a]-positions[$0.b]).length } ?? 0
                if abs(leftLength-rightLength) > 1e-9 { return leftLength > rightLength }
                return left < right
            }
        }

        var placed=Array<[Point2]?>(repeating:nil,count:triangles.count)
        var netIDs=Array<Int?>(repeating:nil,count:triangles.count)
        var net=0
        func place(_ triangle:Triangle, sharedWith parent:Triangle? = nil, parentPoints:[Point2]? = nil) -> [Point2] {
            if let parent, let parentPoints {
                let shared=triangle.ids.filter { parent.ids.contains($0) }
                if shared.count == 2, let ia=triangle.ids.firstIndex(of:shared[0]),let ib=triangle.ids.firstIndex(of:shared[1]),
                   let pa=parent.ids.firstIndex(of:shared[0]),let pb=parent.ids.firstIndex(of:shared[1]),
                   let ic=(0..<3).first(where:{$0 != ia && $0 != ib}) {
                    let A=parentPoints[pa],B=parentPoints[pb], edge=hypot(B.x-A.x,B.y-A.y)
                    let da=(positions[triangle.ids[ic]]-positions[shared[0]]).length*scale
                    let db=(positions[triangle.ids[ic]]-positions[shared[1]]).length*scale
                    if edge > 1e-9 {
                        let along=(da*da-db*db+edge*edge)/(2*edge), height=sqrt(max(0,da*da-along*along))
                        let ux=(B.x-A.x)/edge,uy=(B.y-A.y)/edge,nx = -uy,ny=ux
                        let pp=parent.ids.first(where:{ !shared.contains($0) })!
                        let parentThird=parentPoints[parent.ids.firstIndex(of:pp)!]
                        let sideX=B.x-A.x,sideY=B.y-A.y
                        let thirdX=parentThird.x-A.x,thirdY=parentThird.y-A.y
                        let parentSide=sideX*thirdY-sideY*thirdX
                        let sign=parentSide >= 0 ? -1.0 : 1.0
                        let C=Point2(x:A.x+ux*along+nx*height*sign,y:A.y+uy*along+ny*height*sign)
                        var result=Array(repeating:Point2(x:0,y:0),count:3); result[ia]=A; result[ib]=B; result[ic]=C
                        return result
                    }
                }
            }
            let a=positions[triangle.ids[0]],b=positions[triangle.ids[1]],c=positions[triangle.ids[2]]
            let ab=(b-a).length*scale, ac=(c-a).length*scale, bc=(c-b).length*scale
            let x=ab > 1e-9 ? (ac*ac+ab*ab-bc*bc)/(2*ab) : 0
            return [Point2(x:0,y:0),Point2(x:ab,y:0),Point2(x:x,y:sqrt(max(0,ac*ac-x*x)))]
        }
        func overlaps(_ candidate:[Point2], _ others:[[Point2]]) -> Bool {
            func cross(_ a:Point2,_ b:Point2,_ c:Point2)->Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
            func inside(_ p:Point2,_ t:[Point2])->Bool {
                let a=cross(t[0],t[1],p),b=cross(t[1],t[2],p),c=cross(t[2],t[0],p)
                return (a>1e-5 && b>1e-5 && c>1e-5) || (a < -1e-5 && b < -1e-5 && c < -1e-5)
            }
            for t in others {
                if candidate.contains(where:{inside($0,t)}) || t.contains(where:{inside($0,candidate)}) { return true }
                for i in 0..<3 { for j in 0..<3 {
                    let a=candidate[i],b=candidate[(i+1)%3],c=t[j],d=t[(j+1)%3]
                    if cross(a,b,c)*cross(a,b,d) < -1e-8 && cross(c,d,a)*cross(c,d,b) < -1e-8 { return true }
                }}
            }
            return false
        }
        for root in triangles.indices where placed[root] == nil {
            let rootPoints=place(triangles[root]); placed[root]=rootPoints; netIDs[root]=net
            var queue=[root],head=0
            var existing=[rootPoints]
            while head<queue.count {
                let current=queue[head]; head += 1
                for next in neighbors[current] where placed[next] == nil {
                    let candidate=place(triangles[next],sharedWith:triangles[current],parentPoints:placed[current])
                    if !overlaps(candidate,existing) { placed[next]=candidate; netIDs[next]=net; queue.append(next);existing.append(candidate) }
                }
            }
            net += 1
        }
        var facets:[MeshNetFacet]=[]
        for i in triangles.indices {
            guard let points=placed[i],let assigned=netIDs[i] else { continue }
            let flat=(0..<3).map { k in planarEdges.contains(MeshEdge(triangles[i].ids[k],triangles[i].ids[(k+1)%3])) }
            facets.append(MeshNetFacet(vertices:triangles[i].ids,points:points,planarEdges:flat,net:assigned))
        }
        // Count a hinge only when the shared 3D edge also occupies the same 2D segment.
        var folded=0
        for faces in edgeFaces.values where faces.count == 2 {
            let a=faces[0],b=faces[1]
            if netIDs[a] == netIDs[b], let pa=placed[a],let pb=placed[b] {
                let shared=triangles[a].ids.filter { triangles[b].ids.contains($0) }
                if shared.count==2,let a0=triangles[a].ids.firstIndex(of:shared[0]),let a1=triangles[a].ids.firstIndex(of:shared[1]),let b0=triangles[b].ids.firstIndex(of:shared[0]),let b1=triangles[b].ids.firstIndex(of:shared[1]),
                   hypot(pa[a0].x-pa[a1].x,pa[a0].y-pa[a1].y)>0,
                   hypot((pa[a0].x-pa[a1].x)-(pb[b0].x-pb[b1].x),(pa[a0].y-pa[a1].y)-(pb[b0].y-pb[b1].y))<1e-4 { folded += 1 }
            }
        }
        let cut=max(0,edgeFaces.values.filter{$0.count==1}.count + edgeFaces.values.filter{$0.count==2}.count-folded)
        // Pack disconnected cut nets into rows while retaining the requested physical scale.
        var offsets:[Int:Point2]=[:],cursorX=0.0,cursorY=0.0,rowHeight=0.0
        let maxRowWidth=257.0, gap=6.0
        let groups=Dictionary(grouping:facets,by:\.net).sorted{$0.key<$1.key}
        for (id,items) in groups {
            let xs=items.flatMap{$0.points.map(\.x)},ys=items.flatMap{$0.points.map(\.y)}
            let width=(xs.max() ?? 0)-(xs.min() ?? 0),height=(ys.max() ?? 0)-(ys.min() ?? 0)
            if cursorX > 0 && cursorX+width > maxRowWidth { cursorX=0;cursorY += rowHeight+gap;rowHeight=0 }
            offsets[id]=Point2(x:10+cursorX-(xs.min() ?? 0),y:10+cursorY-(ys.min() ?? 0))
            cursorX += width+gap; rowHeight=max(rowHeight,height)
        }
        let packed=facets.map { facet -> MeshNetFacet in
            let o=offsets[facet.net] ?? Point2(x:10,y:10)
            return MeshNetFacet(vertices:facet.vertices,points:facet.points.map{Point2(x:$0.x+o.x,y:$0.y+o.y)},planarEdges:facet.planarEdges,net:facet.net)
        }
        var best=packed,bestPages=Int.max
        for degrees in stride(from:0,through:315,by:45) {
            let angle=Double(degrees)*Double.pi/180,co=cos(angle),si=sin(angle)
            let rotated=packed.map { facet -> MeshNetFacet in
                MeshNetFacet(vertices:facet.vertices,points:facet.points.map{Point2(x:$0.x*co-$0.y*si,y:$0.x*si+$0.y*co)},planarEdges:facet.planarEdges,net:facet.net)
            }
            let minX=rotated.flatMap{$0.points.map(\.x)}.min() ?? 0,minY=rotated.flatMap{$0.points.map(\.y)}.min() ?? 0
            let shifted=rotated.map { facet in
                MeshNetFacet(vertices:facet.vertices,points:facet.points.map{Point2(x:$0.x+15-minX,y:$0.y+15-minY)},planarEdges:facet.planarEdges,net:facet.net)
            }
            let pages=MeshNetPDF.pageTiles(shifted).count
            if pages<bestPages { best=shifted;bestPages=pages }
        }
        return MeshNetModel(facets:best,pageCount:bestPages,cutEdges:cut,foldedEdges:folded)
    }
}

enum MeshNetPDF {
    static func pageTiles(_ facets:[MeshNetFacet])->[(col:Int,row:Int)] {
        guard !facets.isEmpty else { return [(0,0)] }
        var occupied=Set<String>()
        for facet in facets {
            let minX=facet.points.map(\.x).min()!-5,maxX=facet.points.map(\.x).max()!+5
            let minY=facet.points.map(\.y).min()!-5,maxY=facet.points.map(\.y).max()!+5
            let c0=max(0,Int(floor((minX-277)/267))+1),c1=max(0,Int(floor(maxX/267)))
            let r0=max(0,Int(floor((minY-190)/180))+1),r1=max(0,Int(floor(maxY/180)))
            if c1>=c0 && r1>=r0 {
                for row in r0...r1 { for col in c0...c1 {
                    let rect=CGRect(x:Double(col)*267-5,y:Double(row)*180-5,width:287,height:200)
                    if touches(facet.points,rect:rect) { occupied.insert("\(row):\(col)") }
                }}
            }
        }
        return occupied.compactMap { key in
            let p=key.split(separator:":").compactMap{Int($0)}
            return p.count==2 ? (col:p[1],row:p[0]) : nil
        }.sorted { $0.row == $1.row ? $0.col < $1.col : $0.row < $1.row }
    }
    private static func touches(_ triangle:[Point2],rect:CGRect)->Bool {
        func inside(_ p:Point2,_ r:CGRect)->Bool { p.x>=r.minX && p.x<=r.maxX && p.y>=r.minY && p.y<=r.maxY }
        func cross(_ a:Point2,_ b:Point2,_ c:Point2)->Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        if triangle.contains(where:{inside($0,rect)}) { return true }
        let corners=[Point2(x:rect.minX,y:rect.minY),Point2(x:rect.maxX,y:rect.minY),Point2(x:rect.maxX,y:rect.maxY),Point2(x:rect.minX,y:rect.maxY)]
        func inTriangle(_ p:Point2)->Bool {
            let a=cross(triangle[0],triangle[1],p),b=cross(triangle[1],triangle[2],p),c=cross(triangle[2],triangle[0],p)
            return (a>=0 && b>=0 && c>=0) || (a<=0 && b<=0 && c<=0)
        }
        if corners.contains(where:{inTriangle($0)}) { return true }
        for i in 0..<3 { for j in 0..<4 {
            let a=triangle[i],b=triangle[(i+1)%3],c=corners[j],d=corners[(j+1)%4]
            if cross(a,b,c)*cross(a,b,d)<=0 && cross(c,d,a)*cross(c,d,b)<=0 { return true }
        }}
        return false
    }
    static func write(_ model:MeshNetModel,to url:URL) throws {
        let mm=72.0/25.4, pageW=297.0*mm,pageH=210.0*mm,stepX=267.0,stepY=180.0
        let tiles=pageTiles(model.facets)
        var box=CGRect(x:0,y:0,width:pageW,height:pageH);let data=NSMutableData()
        guard let consumer=CGDataConsumer(data:data as CFMutableData),let context=CGContext(consumer:consumer,mediaBox:&box,nil) else { throw CocoaError(.fileWriteUnknown) }
        let red=NSColor(calibratedRed:0.82,green:0.16,blue:0.15,alpha:1).cgColor,blue=NSColor(calibratedRed:0.12,green:0.42,blue:0.74,alpha:1).cgColor
        var edgeOwners:[MeshEdge:[(MeshNetFacet,Int)]]=[:]
        for facet in model.facets { for i in 0..<3 { edgeOwners[MeshEdge(facet.vertices[i],facet.vertices[(i+1)%3]),default:[]].append((facet,i)) } }
        let matchedEdges=edgeOwners.keys.filter{$0.a != $0.b}.sorted { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }
        let edgeLabels=Dictionary(uniqueKeysWithValues:matchedEdges.enumerated().map{($0.element,$0.offset+1)})
        for (pageIndex,tile) in tiles.enumerated() { let row=tile.row,col=tile.col
            context.beginPDFPage(nil);context.saveGState()
            context.translateBy(x:10*mm,y:pageH-10*mm);context.scaleBy(x:mm,y:-mm);context.translateBy(x:-Double(col)*stepX,y:-Double(row)*stepY)
            context.beginPath();context.addRect(CGRect(x:Double(col)*stepX,y:Double(row)*stepY,width:277,height:190));context.clip()
            for facet in model.facets {
                for i in 0..<3 {
                    let a=facet.points[i],b=facet.points[(i+1)%3],edge=MeshEdge(facet.vertices[i],facet.vertices[(i+1)%3]),owners=edgeOwners[edge] ?? []
                    let folded:Bool
                    if owners.count==2, owners[0].0.net==owners[1].0.net {
                        let other=owners[0].0.vertices == facet.vertices && owners[0].1 == i ? owners[1] : owners[0]
                        let p=other.0.points[other.1],q=other.0.points[(other.1+1)%3]
                        folded = hypot(a.x-p.x,a.y-p.y)<1e-4 && hypot(b.x-q.x,b.y-q.y)<1e-4 || hypot(a.x-q.x,a.y-q.y)<1e-4 && hypot(b.x-p.x,b.y-p.y)<1e-4
                    } else { folded=false }
                    if folded && facet.planarEdges[i] { continue }
                    context.setStrokeColor(folded ? blue : red);context.setLineWidth(folded ? 0.22 : 0.35)
                    if folded { context.setLineDash(phase:0,lengths:[2,1.5]) } else { context.setLineDash(phase:0,lengths:[]) }
                    context.beginPath();context.move(to:CGPoint(x:a.x,y:a.y));context.addLine(to:CGPoint(x:b.x,y:b.y));context.strokePath()
                    if !folded {
                        let dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy)
                        if length>4 {
                            let inset=min(1.5,length*0.12),height=min(4.5,length*0.24)
                            let area=(facet.points[1].x-facet.points[0].x)*(facet.points[2].y-facet.points[0].y)-(facet.points[1].y-facet.points[0].y)*(facet.points[2].x-facet.points[0].x)
                            let direction=area>0 ? -1.0 : 1.0,nx = -dy/length*direction,ny=dx/length*direction
                            let p0=Point2(x:a.x+dx/length*inset,y:a.y+dy/length*inset),p1=Point2(x:b.x-dx/length*inset,y:b.y-dy/length*inset)
                            context.setStrokeColor(red);context.setLineDash(phase:0,lengths:[]);context.beginPath()
                            context.move(to:CGPoint(x:p0.x,y:p0.y));context.addLine(to:CGPoint(x:p1.x,y:p1.y));context.addLine(to:CGPoint(x:p1.x+nx*height,y:p1.y+ny*height));context.addLine(to:CGPoint(x:p0.x+nx*height,y:p0.y+ny*height));context.closePath();context.strokePath()
                        }
                    }
                }
            }
            context.restoreGState()
            let barX=10*mm,barY=12*mm,barLength=100*mm
            context.setStrokeColor(NSColor.black.cgColor);context.setLineWidth(0.7)
            context.beginPath();context.move(to:CGPoint(x:barX,y:barY));context.addLine(to:CGPoint(x:barX+barLength,y:barY));context.strokePath()
            for x in [barX,barX+barLength] { context.beginPath();context.move(to:CGPoint(x:x,y:barY-3));context.addLine(to:CGPoint(x:x,y:barY+3));context.strokePath() }
            let graphics=NSGraphicsContext(cgContext:context,flipped:false);NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
            for facet in model.facets { for i in 0..<3 {
                let edge=MeshEdge(facet.vertices[i],facet.vertices[(i+1)%3]),owners=edgeOwners[edge] ?? []
                guard owners.count==2, owners.contains(where:{$0.0.vertices == facet.vertices && $0.1 == i}),
                      let label=edgeLabels[edge] else { continue }
                let other=owners.first(where:{ !($0.0.vertices == facet.vertices && $0.1 == i) })!
                let a=facet.points[i],b=facet.points[(i+1)%3]
                let p=other.0.points[other.1],q=other.0.points[(other.1+1)%3]
                let isFold=other.0.net==facet.net && (hypot(a.x-p.x,a.y-p.y)<1e-4 && hypot(b.x-q.x,b.y-q.y)<1e-4 || hypot(a.x-q.x,a.y-q.y)<1e-4 && hypot(b.x-p.x,b.y-p.y)<1e-4)
                guard !isFold else { continue }
                let center=Point2(x:(a.x+b.x)/2,y:(a.y+b.y)/2)
                let centroid=Point2(x:facet.points.map(\.x).reduce(0,+)/3,y:facet.points.map(\.y).reduce(0,+)/3)
                let vx=centroid.x-center.x,vy=centroid.y-center.y,length=max(1e-9,hypot(vx,vy))
                let gx=center.x+vx/length*2.2-Double(col)*stepX,gy=center.y+vy/length*2.2-Double(row)*stepY
                let x=(10+gx)*mm,y=pageH-(10+gy)*mm
                ("E\(label)" as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:5.5),.foregroundColor:NSColor.black])
            }}
            let label="CUT red  |  FOLD blue dashed  |  A4 100%  |  page \(pageIndex+1)/\(tiles.count)  |  facets \(model.facets.count)" as NSString
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:8),.foregroundColor:NSColor.darkGray]
            label.draw(at:NSPoint(x:10*mm,y:7*mm),withAttributes:attrs)
            ("100 mm" as NSString).draw(at:NSPoint(x:barX+barLength/2-12,y:barY+4),withAttributes:attrs)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF();try (data as Data).write(to:url,options:.atomic)
    }
}

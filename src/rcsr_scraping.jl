using LinearAlgebra
using HTTP, Gumbo, Cascadia, StaticArrays, PeriodicGraphs, Graphs, CrystalNets
using Base.Threads
CrystalNets.toggle_warning(false)
CrystalNets.toggle_export(false)

import CrystalNets: expand_symmetry, Cell, CIF, export_arc

function cell_parameters(mat::AbstractMatrix)
    _a, _b, _c = eachcol(mat)
    a = norm(_a)
    b = norm(_b)
    c = norm(_c)
    α = acosd(_b'_c/(b*c))
    β = acosd(_c'_a/(c*a))
    γ = acosd(_a'_b/(a*b))
    return (a, b, c), (α, β, γ)
end
function prepare_periodic_distance_computations(mat)
    (a, b, c), (α, β, γ) = cell_parameters(mat)
    ortho = all(x -> isapprox(Float16(x), 90; rtol=0.02), (α, β, γ))
    _a, _b, _c = eachcol(mat)
    safemin = min(Float64(dot(cross(_b, _c), _a)/(b*c)),
                  Float64(dot(cross(_c, _a), _b)/(a*c)),
                  Float64(dot(cross(_a, _b), _c)/(a*b)))/2
    # safemin is the half-distance between opposite planes of the unit cell
    return MVector{3,Float64}(undef), ortho, safemin
end
function periodic_distance!(buffer, u, mat, ortho, safemin)
    @simd for i in 1:3
        diff = u[i] + 0.5
        buffer[i] = diff - floor(diff) - 0.5
    end
    ref = norm(mat*buffer)
    (ortho || ref ≤ safemin) && return ref
    @inbounds for i in 1:3
        buffer[i] += 1
        newnorm = norm(mat*buffer)
        newnorm < ref && return newnorm # in a reduced lattice, there should be at most one
        buffer[i] -= 2
        newnorm = norm(mat*buffer)
        newnorm < ref && return newnorm
        buffer[i] += 1
    end
    return ref
end
periodic_distance!(u, mat, ortho, safemin) = periodic_distance!(u, u, mat, ortho, safemin)
function periodic_distance(u, mat, ortho=nothing, safemin=nothing)
    if ortho === nothing || safemin === nothing
        _, ortho, safemin = prepare_periodic_distance_computations(mat)
    end
    periodic_distance!(similar(u), u, mat, ortho::Bool, safemin::Float64)
end

function getrcsr(n)
    rcsr = String(HTTP.get("http://rcsr.net/data/$(n)dall.txt").body)
    return split(rcsr[match(r"start", rcsr).offset:end], r"(\r\n|\n)")
end

const rcsr3D = getrcsr(3)

function precise_round(x, n)
    u = 10^(n+1)
    y = floor(Int, u*x)
    r = rem(y+5, 10)
    ret = (y - r + ifelse(r == 0, 0, 5)) / u
    ret == 1.0 && return precise_round(x, n+1)
    ret
end

"""
Given a position `u`, return a vector of offsets `ofs` such that `u .+ ofs` are the
periodic images of `u` closest to the origin.
"""
function periodic_neighbor!(buffer, u, mat, ortho, safemin, ε)
    ofs = MVector{3,Int}(undef)
    @simd for i in 1:3
        diff = u[i] + 0.5
        ofs[i] = -floor(Int, diff)
        buffer[i] = diff + ofs[i] - 0.5
    end

    ref = norm(mat*buffer)
    ofss = SVector{3,Int}[ofs]
    ref ≤ safemin && return ofss, ref

    totry = if ortho
        _totry = SVector{3,Int}[]
        for i in 1:3
            if isapprox(buffer[i], -0.5; rtol=0.01)
                __totry = MVector{3,Int}(ofs)
                __totry[i] += 1
                push!(_totry, __totry)
                __totry[i] -= 2
                push!(_totry, __totry)
            end
        end
        _totry
    else
        [ofs .+ x for x in SVector{3,Int}[(1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)]]
    end
    # totry = [ofs .+ x for x in SVector{3,Int}[(1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)]]

    for newofs in totry
        buffer .= u .+ newofs
        newnorm = norm(mat*buffer)
        if newnorm < ref - ε
            ofss[1] = newofs
            resize!(ofss, 1)
            ref = newnorm
        elseif newnorm ≤ ref + ε
            push!(ofss, newofs)
        end
    end
    return ofss, ref
end

"""
Check whether the given graph has the correct list of coordination sequences
"""
function check_graph(g, seqs_unique)
    unique!(sort(degree(g))) != first.(seqs_unique) && return false
    seqs_set = Set(seqs_unique)
    for i in 1:nv(g)
        coordination_sequence(g, i, 10) in seqs_set || return false
    end
    return true
end

"""
    closest_positions(x, mat, poss, ε, maxsize)

Return three lists: `ids`, `dists` and `closest_pos`, where for each index `i`, `i` is the
index of a potential closest neighbour of `x` such that:
- `ids[i]` is the index of the corresponding vertex in list `poss`
- `dists[i]` is the distance between that vertex and `x`
- `closest_pos[i]` is the position of the vertex

The number of closest neighbours returned is at most `maxsize`.

Distances between closest neighbours of `x` cannot differ by more than `ε`
"""
function closest_positions(x, mat, poss, ε, maxsize)
    _, ortho, _safemin = prepare_periodic_distance_computations(mat)
    safemin = 6*_safemin/7
    buffer = MVector{3,Float32}(undef)
    closest_pos = SVector{3,Float32}[]
    ids = Int[]
    dists = Float32[]
    for (i, y) in enumerate(poss)
        ofss, ref = periodic_neighbor!(buffer, x .- y, mat, ortho, safemin, ε)
        append!(ids, i for _ in ofss)
        append!(dists, ref for _ in ofss)
        append!(closest_pos, [y .+ ofs for ofs in ofss])
    end
    sizeI = min(maxsize, length(dists))
    I = sizeI == length(dists) ? sortperm(dists) : collect(partialsortperm(dists, 1:sizeI))
    if ε != Inf
        d1 = dists[I[1]]
        for i in 2:sizeI
            if dists[I[i]] > d1 + ε
                resize!(I,  i-1)
                break
            end
        end
    end
    return ids[I], dists[I], closest_pos[I]
end

function nearest_neighbors(x, poss, dpos, mat, ε, round_i, maxsize=6)
    ids, dists, closest_pos = closest_positions(x, mat, poss, ε, maxsize)
    ret = PeriodicEdge3D[]
    for (d, pos) in zip(dists, closest_pos)
        otherpos = x .- (pos .- x) # so that x is the midpoint of pos and otherpos
        ofspos = floor.(Int, pos)
        ofsother = floor.(Int, otherpos)
        src = get(dpos, round.(pos .- ofspos; digits=round_i), nothing)
        src === nothing && continue
        dst = get(dpos, round.(otherpos .- ofsother; digits=round_i), nothing)
        dst === nothing && continue
        src == dst && ofsother == ofspos && continue # avoid loop
        edg = directedge(src, dst, ofsother .- ofspos)
        push!(ret, edg)
    end
    sort!(ret); unique!(ret)
    return ret
end

function try_from_edges_old(_cife, mat, round_i, pos, dpos, ε, seqs)
    cife = expand_symmetry(_cife)
    pose = [SVector{3,Float32}(round.(x; digits=round_i+1)) for x in eachcol(cife.pos)]
    @assert allunique(pose)
    nns = [nearest_neighbors(x, pos, dpos, mat, ε, round_i) for x in pose]
    progression = [length(nn) for nn in nns]
    progression[end] = 0
    progression_made = true
    edgs = PeriodicEdge3D[]
    counter = 0
    while progression_made
        progression_made = false
        empty!(edgs)
        counter ≥ 8192 && break
        counter += 1
        for (i, nn) in enumerate(nns)
            if !progression_made
                if progression[i] == length(nn)
                    progression[i] = isempty(nn) ? 0 : 1
                else
                    progression[i] += 1
                    progression_made = true
                end
            end
            isempty(nn) && continue
            push!(edgs, nn[progression[i]])
        end
        g = PeriodicGraph(edgs)
        check_graph(g, seqs) && return g
    end
    return nothing
end

function try_from_edges_new(cell, poss, poses, dpos, round_i, seqs)
    mat = Float64.(cell.mat)
    edgs = PeriodicEdge3D[]
    npos = NTuple{2,SVector{3,Float32}}[]
    for pose in poses
        idxs, _, closest_pos = closest_positions(pose, mat, poss, 3*exp10(-round_i), 2)
        length(idxs) < 2 && return nothing
        ofs = floor.(Int, closest_pos[2]) .- floor.(Int, closest_pos[1])
        idxs[1] == idxs[2] && iszero(ofs) && return nothing
        push!(edgs, directedge(idxs[1], idxs[2], ofs))
        push!(npos, (closest_pos[1], closest_pos[2]))
    end
    n = length(edgs)
    for i in 1:n
        posa, posb = npos[i]
        for eq in cell.equivalents
            fulla = eq(posa)
            ofsa = floor.(Int, fulla)
            keya = round.(fulla .- ofsa; digits=round_i)
            if !haskey(dpos, keya)
                keya = Float32.(precise_round.(fulla .- ofsa, round_i))
            end
            haskey(dpos, keya) || return nothing
            a = dpos[keya]
            fullb = eq(posb)
            ofsb = floor.(Int, fullb)
            keyb = round.(fullb .- ofsb; digits=round_i)
            if !haskey(dpos, keyb)
                keyb = Float32.(precise_round.(fullb .- ofsb, round_i))
            end
            haskey(dpos, keyb) || return nothing
            b = dpos[keyb]
            push!(edgs, PeriodicEdge(a, b, ofsb .- ofsa))
        end
    end
    g = PeriodicGraph(edgs)
    check_graph(g, seqs) && return g
    return nothing
end

function try_from_closest(mat, poss, seqs)
    edgs = PeriodicEdge3D[]
    for (i, pos) in enumerate(poss)
        idxs, _, closest_pos = closest_positions(pos, mat, poss, Inf, seqs[i][1] + 1)
        length(closest_pos) == seqs[i][1] + 1 || return nothing
        @assert idxs[1] == i && iszero(floor.(Int, closest_pos[1]))
        popfirst!(idxs); popfirst!(closest_pos)
        append!(edgs, PeriodicEdge3D(i, idx, floor.(Int, pos)) for (idx, pos) in zip(idxs, closest_pos))
    end
    g = PeriodicGraph(edgs)
    check_graph(g, seqs) && return g
    nothing
end


function try_from_closest_OLD(_cifv::CIF, cifv::CIF, mat, round_i, poss, dpos, ε, seqs)
    n = length(_cifv.ids)
    m = length(cifv.ids)
    num_symm = length(cifv.cell.equivalents)
    @assert num_symm == length(_cifv.cell.equivalents)

    symmetries = Vector{Tuple{Vector{PeriodicVertex3D},SMatrix{3,3,Int,9}}}(undef, num_symm)
    posbuffer = MVector{3,Float32}(undef)
    ofsbuffer = MVector{3,Int}(undef)

    equivalents = cifv.cell.equivalents
    #=@inbounds=#for (j, equiv) in enumerate(equivalents)
        newpos = Vector{PeriodicVertex3D}(undef, m)
        for i in 1:m
            posbuffer .= equiv.mat * cifv.pos[:,i] .+ equiv.ofs
            ofsbuffer .= floor.(Int, posbuffer)
            v = dpos[round.(posbuffer .- ofsbuffer; digits=round_i)]
            newpos[i] = PeriodicVertex3D(v, ofsbuffer)
        end
        symmetries[j] = (newpos, equiv.mat)
    end
    I = sortperm(symmetries; by=x->(x[1], reshape(x[2], 9)))
    todelete = Int[]
    for i in 2:length(I)
        if symmetries[I[i]] == symmetries[I[i-1]]
            push!(todelete, i)
        end
    end
    if !isempty(todelete)
        deleteat!(I, todelete)
        equivalents = cifv.cell.equivalents[I]
        symmetries = symmetries[I]
    end

    closest_neighbours = Vector{Vector{PeriodicVertex3D}}(undef, n)
    for (i, pos) in enumerate(eachcol(_cifv.pos))
        idxs, _, closest_pos = closest_positions(pos, mat, poss, ε, seqs[i][1] + 3)
        @assert length(closest_pos) ≥ seqs[i][1] + 1
        closest_neighbours[i] = [PeriodicVertex3D(idx, floor.(Int, pos)) for (idx, pos) in zip(idxs, closest_pos)]
        @assert closest_neighbours[i][1] == PeriodicVertex3D(i)
        popfirst!(closest_neighbours[i])
    end

    orbits = [[symm[1][i] for symm in symmetries] for i in 1:m]
    rots = [symm[2] for symm in symmetries]
    progression = ones(Int, n)
    progression[1] = 0
    progression_made = true
    edgs = PeriodicEdge3D[]
    g = PeriodicGraph3D()
    while progression_made
        progression_made = false
        skip_check_g = false
        empty!(edgs)
        for (i, closest) in enumerate(closest_neighbours)
            progression_made_now = !progression_made
            if progression_made_now
                if progression[i] == length(closest)
                    progression[i] = 1
                    progression_made_now = false
                    skip_check_g = true
                else
                    progression[i] += 1
                    progression_made = true
                end
            end
            neigh = closest[progression[i]]
            if progression_made_now && !skip_check_g
                initial_level = progression[i] - 1
                while has_edge(g, PeriodicEdge3D(i, neigh))
                    if progression[i] == length(closest)
                        progression[i] = initial_level
                        neigh = closest[progression[i]]
                        progression_made = false
                        break
                    end
                    progression[i] += 1
                    neigh = closest[progression[i]]
                end
            end

            push!(edgs, PeriodicEdge3D(i, neigh))
            for (ui, uneigh, rot) in zip(orbits[i], orbits[neigh.v], rots)
                push!(edgs, PeriodicEdge3D(ui.v, uneigh.v, rot*neigh.ofs .+ uneigh.ofs .- ui.ofs))
            end
        end
        g = PeriodicGraph(edgs)
        check_graph(g, seqs) && return g
    end
    return nothing
end

function determine_graph(_cifv, _cife, cell, _seqs)
    cifv = expand_symmetry(_cifv)
    mat = Float64.(cell.mat)
    # seqs = _seqs[cifv.ids]
    seqs_unique = unique!(sort(_seqs))
    _posv = Float32.(cifv.pos)
    pos = _posv
    _pose = Float32.(_cife.pos)
    pose = _pose
    round_i = 1
    while round_i ≤ 8
        pos = [SVector{3,Float32}(x) for x in eachcol(round.(_posv; digits=round_i))]
        pose = [SVector{3,Float32}(x) for x in eachcol(round.(_pose; digits=round_i))]
        round_i += 1
        allunique(pos) && break
    end
    pos = [SVector{3,Float32}(x) for x in eachcol(precise_round.(_posv, round_i))]
    pose = [SVector{3,Float32}(x) for x in eachcol(precise_round.(_pose, round_i))]
    @assert allunique(pos)
    dpos = Dict{SVector{3,Float32},Int}([p => j for (j,p) in enumerate(pos)])
    ε = cbrt(det(mat) / length(cifv.ids))

    # g1 = try_from_closest(_cifv, cifv, mat, round_i, pos, dpos, ε, seqs_unique)
    g1 = try_from_closest(mat, pos, seqs_unique)
    g1 === nothing || return g1

    pos_precise = [SVector{3,Float32}(x) for x in eachcol(precise_round.(_posv, round_i+1))]
    g2 = try_from_edges_new(cell, pos_precise, pose, dpos, round_i, seqs_unique)
    g2 === nothing || return g2

    g3 = try_from_edges_old(_cife, mat, round_i, pos, dpos, ε, seqs_unique)
    g3 === nothing || return g3

    return nothing
end


"""
Organizes the RCSR web data into a list of names, CIF (for vertices and edges), cells and
coordination sequences. Also records invalid symmetries.
"""
function extract_rcsr_data(rcsr=rcsr3D)
    nrcsr = length(rcsr)
    symmetry_issues = Tuple{String,String,Int}[]
    names = String[]
    cifvs = CIF[]
    cifes = CIF[]
    cells = Cell[]
    seqss = Vector{Vector{Int}}[]
    i = 2
    while i < nrcsr
        last_i = i
        strip(rcsr[i]) == "-1" && break
        i += 1
        name = strip(rcsr[i])
        i += 2
        try
            weaving = false
            for j in 1:5
                name ∈ ("cdz-e", "ssf-e", "bor-y", "pok", "qok", "sfo", "rok") || @assert rcsr[i][1] == ' '
                splits = split(rcsr[i])
                num = parse(Int, first(splits))
                if j == 4
                    @assert last(splits) == "keywords"
                    if num != 0
                        for _ in 1:num
                            i += 1
                            if strip(rcsr[i]) == "weaving"
                                weaving = true
                            end
                        end
                    end
                    i += 1
                else
                    i += num + 1
                end
            end

            _symb, _spgroup = split(rcsr[i])
            spgroup = parse(Int, _spgroup)
            symb = filter(x -> x != '(' && x != ')', _symb)
            hall = get(CrystalNets.PeriodicGraphEmbeddings.SPACE_GROUP_HM, symb, 0)
            if hall == 0
                hall = CrystalNets.PeriodicGraphEmbeddings.SPACE_GROUP_IT[spgroup]
                push!(symmetry_issues, (name, _symb, spgroup))
                # @info "Invalid symmetry $symb for $name (defaulting to $hall from spgroup $spgroup)"
            elseif hall != CrystalNets.PeriodicGraphEmbeddings.SPACE_GROUP_IT[spgroup]
                @warn "symb $symb leads to hall number $hall but spgroup $spgroup leads to $(CrystalNets.PeriodicGraphEmbeddings.SPACE_GROUP_IT[spgroup])"
            end

            i += 1
            a, b, c, α, β, γ = parse.(Float64, split(rcsr[i]))
            cell = Cell(hall, (512*a, 512*b, 512*c), (α, β, γ))

            i += 1
            numv = parse(Int, rcsr[i])
            posv = Matrix{Float64}(undef, 3, numv)
            coordination = Vector{Int}(undef, numv)

            i += 1
            for v in 1:numv
                splits = split(rcsr[i])
                name ∈ ("odf-d", "gwe-a", "qtz-t", "moo", "cot-a", "fnh-b", "zaz", "lwa-d") || @assert splits[1] == "V"*string(v)
                coordination[v] = parse(Int, splits[2])
                i += 1
                posv[:, v] .= parse.(Float64, split(rcsr[i]))
                i += 5
            end

            nume = parse(Int, rcsr[i])
            pose = Matrix{Float64}(undef, 3, nume)
            i += 1
            for e in 1:nume
                splits = split(rcsr[i], x -> isspace(x) || !isprint(x); keepempty=false)
                @assert splits[2] == "2"
                name ∈ ("ntb", "bcu-dia-c", "oku") || splits[1] == "E"*string(e) || @warn "$(splits[1]) != E$e for $name"
                i += 1
                pose[:, e] .= try parse.(Float64, split(rcsr[i])) catch; NaN end
                i += 4
            end

            i += 5
            seqs = Vector{Vector{Int}}(undef, numv)
            for v in 1:numv
                seq = parse.(Int, split(rcsr[i]))
                @assert length(seq) == 11
                name ∈ ("xxv", "rpa", "qyc", "ecz", "ocf", "szp") || @assert seq[1] == coordination[v]
                pop!(seq)
                seqs[v] = seq
                i += 1
            end
            if name == "xxv"
                @assert length(seqs) == 2
                seqs[1], seqs[2] = seqs[2], seqs[1]
                @assert seqs[1][1] == coordination[1]
                @assert seqs[2][1] == coordination[2]
            elseif name == "qyc"
                @assert seqs[3][1] == 3
                seqs[3][1] = 4
            end

            if !weaving # store the net
                push!(names, name)
                push!(cifvs, CIF(Dict{String, Union{String, Vector{String}}}(), cell,
                    collect(1:numv), [Symbol("") for _ in 1:numv], posv, Vector{Tuple{Int,Float32}}[]))
                push!(cifes, CIF(Dict{String, Union{String, Vector{String}}}(), cell,
                    collect(1:nume), [Symbol("") for _ in 1:nume], pose, Vector{Tuple{Int,Float32}}[]))
                push!(cells, cell)
                push!(seqss, seqs)
            end

            while i < length(rcsr) && !occursin("start", rcsr[i])
                i += 1
            end
            i += 1
        catch e
            @show name, last_i
            rethrow()
        end
    end
    I = sortperm(names)
    return names[I], cifvs[I], cifes[I], cells[I], seqss[I], symmetry_issues
end


function deaugment(graph::PeriodicGraph{N}) where N
    ra = RingAttributions(graph, 2)
    groups = Vector{PeriodicVertex{N}}[]
    groupdict = Dict{Int,Tuple{Int,SVector{N,Int}}}()
    n = nv(graph)
    I = sort(1:n; by=i->minimum(length, ra[i]; init=0))
    visited = falses(n)
    for retry in (false, true)
        for i in I
            visited[i] && continue
            visited[i] = true
            cycles = [(c, zero(SVector{N,Int})) for c in ra[i]]
            minclen = minimum(x -> length(x[1]), cycles; init=0)
            group = PeriodicVertex{N}[PeriodicVertex{N}(i)]
            push!(groups, group)
            groupdict[i] = (length(groups), zero(SVector{N,Int}))
            for (c, ofs) in cycles
                retry && length(c) > minclen+2 && continue
                any(((v,_),) -> visited[v] && groupdict[v][1] != length(groups), c) && break
                for (v, vertex_ofs) in c
                    visited[v] && continue
                    visited[v] = true
                    newofs = vertex_ofs + ofs
                    groupdict[v] = (length(groups), newofs)
                    push!(group, PeriodicVertex{N}(v, newofs))
                    append!(cycles, (c2, newofs) for c2 in ra[v])
                end
            end
        end
        length(groups) == 1 || break
        visited = falses(n)
    end
    g = PeriodicGraph{N}(length(groups))
    for (i, group) in enumerate(groups)
        for (u, ofs_u) in group
            for (v, ofs_v) in neighbors(graph, u)
                j, ofs_j = groupdict[v]
                newofs = ofs_j - ofs_v - ofs_u
                i == j && iszero(newofs) && continue
                add_edge!(g, PeriodicEdge{N}(i, j, newofs))
            end
        end
    end
    g
end

function look_for_deaugment()
    ret = Dict{String,String}()
    for (name, graph) in REVERSE_CRYSTALNETS_ARCHIVE
        root = split(name, ',')[1]
        (root[end] == 'a' && root[end-1] == '-') || continue
        root = root[1:end-2]
        haskey(REVERSE_CRYSTALNETS_ARCHIVE, root) && continue
        newg = deaugment(PeriodicGraph(graph))
        idx = findfirst(==(root), names)
        idx isa Nothing && ((@warn "Could not find $root"); continue)
        if check_graph(newg, unique!(sort(seqss[idx])))
            genome = string(PeriodicGraph(topological_genome(CrystalNet(newg))))
            reference = get(CrystalNets.CRYSTALNETS_ARCHIVE, genome, nothing)
            if reference isa String
                startswith(reference, root) && continue
                @error "Found another graph for $root: \"$reference\", \"$genome\""
            end
            ret[root] = genome
        end
    end
    ret
end

"""
    extract_graphs(rcsr=rcsr3D, onlynew=true)

Automatically collect the periodic graph corresponding to the nets in the RCSR.

If `onlynew` is set, only return the graphs that are not already in the CrystalNets archive.
"""
function extract_graphs(rcsr=rcsr3D, onlynew=true)
    names, cifvs, cifes, cells, seqss, symmetry_issues = extract_rcsr_data(rcsr)
    n = length(names)
    ret = Vector{Pair{String,PeriodicGraph3D}}(undef, n)
    errored = [Int[] for _ in 1:nthreads()]
    failed = [Int[] for _ in 1:nthreads()]
    @threads for i in 1:n
        name = names[i]
        cifv = cifvs[i]
        cife = cifes[i]
        cell = cells[i]
        seqs = seqss[i]
        graph = try
            determine_graph(cifv, cife, cell, seqs)
        catch
            push!(errored[threadid()], i)
            continue
        end
        if graph isa PeriodicGraph3D
            ret[i] = name => graph
        else
            push!(failed[threadid()], i)
        end
    end
    _failed = reduce(vcat, failed)
    _errored = reduce(vcat, errored)
    toremove = vcat(_failed, _errored)
    if onlynew
        for i in 1:length(ret)
            isassigned(ret, i) || continue
            name, graph = ret[i]
            reference_s = get(REVERSE_CRYSTALNETS_ARCHIVE, name, nothing)
            reference_s isa String || continue
            genome = string(PeriodicGraph(topological_genome(CrystalNet(graph))))
            if genome != reference_s
                @error "Found another graph for $name: \"$reference_s\", \"$genome\""
            end
            push!(toremove, i)
        end
    end
    sort!(toremove)
    deleteat!(ret, toremove)

    retdict = Dict(ret)
    remove_from_failed = Int[]
    for failed_i in _failed
        name = names[failed_i]
        graph = get(retdict, string(name, "-a"), nothing)
        if graph isa PeriodicGraph
            newg = deaugment(graph)
            if check_graph(newg, unique!(sort(seqss[failed_i])))
                retdict[name] = newg
                @show name
                push!(remove_from_failed, failed_i)
            end
        end
    end
    deleteat!(_failed, remove_from_failed)
    return retdict, names[_failed], names[_errored], symmetry_issues
end

"""
Create a new .arc from the successful parsed topologies
"""
function export_new_archive(path, rcsr=rcsr3D)
    archive, failed, errored, symms = extract_graphs(rcsr)
    list_archive = collect(archive)
    n = length(list_archive)
    ret = Vector{Tuple{String,String}}(undef, n)
    keep = trues(n)
    println("EXPORTING")
    @threads for i in 1:n
        id, graph = list_archive[i]
        g = topological_genome(CrystalNet(graph))
        keep[i] = !g.unstable && isempty(g.error)
        ret[i] = (string(PeriodicGraph(g)), id)
    end
    keepat!(ret, keep)
    export_arc(path, ret)
end

# Main entrypoint: export_new_archive("/tmp/rcsr.arc", rcsr3D)
# then diff with the current rcsr.arc


# Utility for comparing with EPINET

function altnamesrcsr(rcsr=rcsr3D)
    ret = Pair{String,Vector{String}}[]
    @assert rcsr[1] == "start" || rcsr[1] == " start"
    i = 1
    flag = true
    while flag
        i += 1
        num = rcsr[i]
        num == "-1" && break
        i += 1
        net = rcsr[i]
        @assert !haskey(Dict(ret), net)
        while true
            i += 1
            if i > length(rcsr)
                flag = false
                break
            end
            l = rcsr[i]
            if endswith(l, "number of names")
                num = parse(Int, split(l)[1])
                altnames = String[]
                for _ in 1:num
                    i += 1
                    l = rcsr[i]
                    push!(altnames, strip(l))
                end
                push!(ret, (strip(net) => altnames))
                break
            end
        end
        while true
            i += 1
            if i > length(rcsr)
                flag = false
                break
            end
            l = rcsr[i]
            occursin(l, "start") && break
        end
    end
    d = Dict(ret)
    @assert length(d) == length(ret)
    return d
end

function epinet_comparison(altnames=altnamesrcsr())
    ret = Pair{String,Int}[]
    for (k, v) in altnames
        for name in v
            if startswith(name, "sqc") && all(isnumeric, name[4:end])
                push!(ret, (k => parse(Int, name[4:end])))
            end
        end
    end
    d = Dict(ret)
    @assert length(d) == length(ret)
    return d
end




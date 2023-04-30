# 18.337 Project - Learning cable tension vectors in multi-drone slung load carrying
# 
# Author: Harvey Merton


begin
   using DifferentialEquations 
   using Rotations
   using LinearAlgebra
   using Flux
   include("utils.jl")
   include("datatypes.jl")
end

begin
    const NUM_DRONES = 3 
end

# Function that returns num_drones drone inputs (forces and moments) at a specified time
# Currently set values close to quasi-static state-regulation inputs. TODO: might need to change to include horizonal components 
# TODO: Perhaps try trajectory-following
function drone_forces_and_moments(params, t::Float64)
    # Preallocate the output vector
    fₘ = [[0.0, Vector{Float64}(undef, 3)] for i in 1:params.num_drones]
    
    # Store the force and moment inputs for each drone
    for i in 1:params.num_drones
        fₘ[i][1] = (params.m_drones[i]+params.m_cables[i])*params.g + params.m_load/params.num_drones # Force
        fₘ[i][2] = [0.0, 0.0, 0.0] # Moment
    end

    return fₘ
end


# Function that returns num_drones drone inputs (forces and moments) at a specified time
# The forces, moments and tensions are calculated based on the current drone/load arrangement to give quasi-static behaviour 
# i.e. no accelerations (linear or angular) of drones or load
# function drone_forces_and_moments_quasi_static(params, t::Float64)
#     # Preallocate the output vector
#     fₘ = [[0.0, Vector{Float64}(undef, 3)] for i in 1:params.num_drones]
    
#     # Store the force and moment inputs for each drone
#     for i in 1:params.num_drones
#         fₘ[i][1] = (params.m_drones[i]+params.m_cables[i])*params.g + params.m_load/params.num_drones # Force
#         fₘ[i][2] = [0.0, 0.0, 0.0] # Moment
#     end


#     # Load EOM
#     # Acceleration
#     ∑RₗTᵢqᵢ = -p.m_load*p.g*e₃

#     # Angular acceleration
#     #0 = inv(p.j_load)*(∑rᵢx-Tᵢqᵢ - cross(Ωₗ,(p.j_load*Ωₗ)))


#     # Drones EOM
#     # Acceleration
#     0 = (fᵢ*Rᵢ*e₃ - p.m_drones[i]*p.g*e₃ + Rₗ*Tᵢqᵢ)



#     return fₘ
# end


# Function that returns num_drones tension vectors for the massless cable case
function cable_tensions_load_side(ẍₗ, Ωₗ, αₗ, Rₗ, params)
    e₃ = [0,0,1] 

    # Create matricies required for Euler-Newton tension calculations
    # ϕ is I's and hat mapped r's for transforming wrench to tensions
    # N is the kernal of ϕ
    ϕ = [Matrix{Float64}(I, params.num_drones, params.num_drones) for _ in 1:2, _ in 1:params.num_drones] # 2xn matrix of I matricies #Matrix{Float64}(undef, 2*params.num_drones, 3*params.num_drones)
    #num_N_rows = 3*params.num_drones
    N = [zeros(params.num_drones) for _ in 1:params.num_drones, _ in 1:params.num_drones] #nxn matrix of vectors #Matrix{Float64}(undef, num_N_rows, params.num_drones)
    n_col = 1

    # Loop through all cable attachment points
    for i in 1:params.num_drones
        # Generate ϕ column by column
        ϕ[2,i] = hat_map(params.r_cables[i])

        # Generate N column by column
        for j in i:params.num_drones #i is cols, j is rows
            if i != j
                # Unit vector from ith cable's attachement point to jth cable's attachment point
                r₍j_rel_i₎ = params.r_cables[j] - params.r_cables[i]
                u₍ij₎ = r₍j_rel_i₎/norm(r₍j_rel_i₎)
                
                # Generate next N column using unit vectors between cable attachment points on load
                N_next_col = [zeros(3) for _ in 1:params.num_drones]
                println(N_next_col)
                println(u₍ij₎)

                N_next_col[i] = u₍ij₎
                N_next_col[j] = -u₍ij₎
                N[:,n_col] = N_next_col

                n_col +=1
            end
        end
    end

    # Wrench calculations
    W = -(vcat(transpose(Rₗ)*(params.m_load*(ẍₗ + params.g*e₃)), (params.j_load*αₗ + cross(Ωₗ, params.j_load*Ωₗ))))

    # Internal force components (defined here to produce zero isometric work)
    Λ = zeros(params.num_drones)
    
    # Calculate T's
    T = unflatten_v(pinv(flatten_m(ϕ))*W + flatten_m(N)*Λ, 3)
    # T = unflatten_v(T, 3) #[(params.num_drones,) for _ in 1:params.num_drones])
  
    return T
end



# u = x = []
# TODO: might need to flatten and unflatten matricies if using ForwardDiff
# TODO: replace all du= with du.=
function ode_sys_drone_swarm_nn!(du,u,p,t)
    # Get force and moment inputs from drones
    fₘ = drone_forces_and_moments(p, t)

    ## Variable unpacking 
    e₃ = [0,0,1] 

    # Load
    xₗ = u[p.num_drones*4+1]
    ẋₗ = u[p.num_drones*4+2]
    θₗ = u[p.num_drones*4+3]
    Ωₗ = u[p.num_drones*4+4]

    Rₗ = RotZYX(θₗ[1], θₗ[2], θₗ[3]) # RPY angles to rotation matrix. Use Rotations.params(RotZYX(R)) to go other way

    ## Equations of motion
    ## Load
    ∑RₗTᵢ_load = zeros(3)
    ∑rᵢxTᵢ_load = zeros(3)

    # Calculate cumulative effect of cables on load
    for i in 1:p.num_drones
        Tᵢ_drone = u[4*p.num_drones + 4 + i]
        Tᵢ_load = u[5*p.num_drones + 4 + i]

        # Use massless assumption
        if p.use_nn == false
            # Check massless cables, quasi-static assumption - tension vectors on drone and load are equal and opposite
            if !are_opposite_directions(Tᵢ_drone, Tᵢ_load)
                error("Tension vectors do not meet massless cable assumption")
            end

        end

        # Sum across all cables needed for load EOM calculations
        ∑RₗTᵢ_load += Rₗ*Tᵢ_load # Forces
        ∑rᵢxTᵢ_load += cross(p.r_cables[i],-Tᵢ_load) # Moments

    end
    # HEREEE
        #x_Dᵢ_rel_Lᵢ = inv(Rₗ)*(xᵢ - xₗ) - p.r_cables[i] # = -qᵢ
        qᵢ = -inv(Rₗ)*(xᵢ - xₗ) - p.r_cables[i]



    # Load EOM
    # Velocity
    du[1+4*p.num_drones] = ẋₗ

    # Acceleration
    ẍₗ = (1/p.m_load)*(-∑RₗTᵢ_load-p.m_load*p.g*e₃)
    du[2+4*p.num_drones] = ẍₗ

    # Angular velocity
    du[3+4*p.num_drones] = Ωₗ #R_L_dot

    # Angular acceleration
    αₗ = inv(p.j_load)*(∑rᵢxTᵢ_load - cross(Ωₗ,(p.j_load*Ωₗ)))
    du[4+4*p.num_drones] = αₗ


    # All drones
    for i in 1:p.num_drones
        ### Variable unpacking
        # Drone states
        xᵢ = u[i]
        ẋᵢ = u[p.num_drones+i]
        θᵢ = u[2*p.num_drones+i]
        Ωᵢ = u[3*p.num_drones+i] # Same as θ̇ᵢ

        Rᵢ = RotZYX(θᵢ[1], θᵢ[2], θᵢ[3]) # RPY angles to rotation matrix. Use Rotations.params(RotZYX(R)) to go other way

        # Connections (after drone and load in u)
        Tᵢ_drone = u[4*p.num_drones + 4 + i]
        #Tᵢ_load = u[5*p.num_drones + 4 + i]

        # Inputs 
        fᵢ = fₘ[i][1]
        mᵢ = fₘ[i][2]


        ### Equations of motion
        ## Drones
        # Velocity
        du[i] = ẋᵢ

        # Acceleration
        ẍᵢ = (1/p.m_drones[i])*(fᵢ*Rᵢ*e₃ - p.m_drones[i]*p.g*e₃ + Tᵢ_drone) #ORIENTATION NOT DEFINED BY R_L??? R_L*T_i_drone). Should the e₃ after fᵢ*Rᵢ be there???
        du[i+p.num_drones] = ẍᵢ

        # Angular velocity
        du[i+2*p.num_drones] = Ωᵢ

        # Angular acceleration
        # αᵢ = inv(p.j_drones[i])*(mᵢ - cross(Ωᵢ,(p.j_drones[i]*Ωᵢ)))
        du[i+3*p.num_drones] = inv(p.j_drones[i])*(mᵢ - cross(Ωᵢ,(p.j_drones[i]*Ωᵢ)))

        ## Connection (note these come after load indicies to make it easier to change if required)    
        # Drone motion relative to associated cable's connection point on load (for tension vector neural network)



        # HEREREEEEE - Make so can swap out for massless case for generating training data



        x_Dᵢ_rel_Lᵢ = inv(Rₗ)*(xᵢ - xₗ) - p.r_cables[i]
        ẋ_Dᵢ_rel_Lᵢ = ẋᵢ - (ẋₗ + cross(Ωₗ,p.r_cables[i]))

        ẍ_Lᵢ = ẍₗ + cross(αₗ, p.r_cables[i]) + cross(Ωₗ, cross(Ωₗ, p.r_cables[i])) # Acceleration of point on load where cable is attached
        ẍ_Dᵢ_rel_Lᵢ = ẍᵢ - ẍ_Lᵢ - cross(αₗ, x_Dᵢ_rel_Lᵢ) - cross(Ωₗ, cross(Ωₗ,x_Dᵢ_rel_Lᵢ)) - 2*cross(Ωₗ,ẋ_Dᵢ_rel_Lᵢ)
        
        # Drone side
        nn_ip = vcat(x_Dᵢ_rel_Lᵢ, ẋ_Dᵢ_rel_Lᵢ, ẍ_Dᵢ_rel_Lᵢ)
        nn_ip = convert.(Float32, nn_ip)

        du[i+4*p.num_drones+4] = p.T_dot_drone_nn(nn_ip)

        # Load side
        du[i+5*p.num_drones+4] = p.T_dot_load_nn(nn_ip)

    end

end


begin
    ## Set initial conditions
    u0 = [Vector{Float64}(undef, 3) for i in 1:(6*NUM_DRONES+4)]
    
    # Add drones and cables ICs
    for i in 1:NUM_DRONES
        ## Drones
        # Position
        u0[i] = i*ones(3)

        # Velocity
        u0[NUM_DRONES+i] = i*ones(3)

        # Orientation
        u0[2*NUM_DRONES+i] = i*ones(3)

        # Angular velocity
        u0[3*NUM_DRONES+i] = i*ones(3)

        ## Cables
        # Drone side
        u0[4*NUM_DRONES + 4 + i] = i*ones(3)

        # Load side
        u0[5*NUM_DRONES + 4 + i] = i*ones(3)

    end
    # Load ICs
    # Velocity
    u0[1+4*NUM_DRONES] = 100*ones(3)

    # Acceleration
    u0[2+4*NUM_DRONES] = 100*ones(3)

    # Angular velocity
    u0[3+4*NUM_DRONES] = 100*ones(3)

    # Angular acceleration
    u0[4+4*NUM_DRONES] = 100*ones(3)

    ## Setup parameters
    # Cable tension NNs - take in flattened vector inputs, output tension vector at drone and load respectively
    input_dim = 9 # Position, velocity and acceleration vectors for each drone relative to the attachment point of their attached cables on the load
    nn_T_dot_drone = Chain(Dense(input_dim, 32, tanh), Dense(32, 3)) # TODO: Currently 1 hidden layer - could try 2!!
    nn_T_dot_load = Chain(Dense(input_dim, 32, tanh), Dense(32, 3))

    # Initialise parameter struct
    j_drone = [2.32 0 0; 0 2.32 0; 0 0 4]

    params = DroneSwarmParams_init(num_drones=NUM_DRONES, g=9.81, m_load=0.225, m_drones=[0.5, 0.5, 0.5], m_cables=[0.1, 0.1, 0.1], 
                                    j_load = [2.1 0 0; 0 1.87 0; 0 0 3.97], j_drones= [j_drone, j_drone, j_drone], 
                                    r_cables = [[-0.42, -0.27, 0], [0.48, -0.27, 0], [-0.06, 0.55, 0]], T_dot_drone_nn=nn_T_dot_drone, T_dot_load_nn=nn_T_dot_load)

end

begin
    # TEST!!!!!!!!!
    ## Solve
    # du = [Vector{Float64}(undef, 3) for i in 1:(6*NUM_DRONES+4)]
    # t = 1.0
    # # print(typeof(du))
    # # print(typeof(u0))
    # #println(u0)

    # ode_sys_drone_swarm_nn!(du,u0,params,t)

    # print(du)

    ẍₗ = [1, 1, 1]
    Ωₗ = [2, 2, 2]
    αₗ = [3, 3, 3]
    Rₗ = RotZYX(0.1, 0.1, 0.1) 

    T = cable_tensions_load_side(ẍₗ, Ωₗ, αₗ, Rₗ, params)
    print(T)

    # # Example parameter
    # a = 0.5

    # # Example initial conditions and time span (assuming u contains 2x2 matrices)
    # u0 = [rand(2, 2) for _ in 1:3]
    # tspan = (0.0, 1.0)

    # # Solve the ODE system
    # using DifferentialEquations
    # prob = ODEProblem(ode_sys_drone_swarm_nn!, u0, tspan, (nn_model1, nn_model2, a))
    # sol = solve(prob, Tsit5()) 



    ## Train
    # Train with same ODE simply with tension vectors defined using quasi-static assumption like in paper
    # Will later do using real data from simulator

end
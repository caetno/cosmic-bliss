<!--
source: https://obi.virtualmethodstudio.com/manual/6.1/convergence.html
fetched: 2026-05-03T12:52:46+00:00
-->

# Simulation

The information in this page will give you deeper insight into how Obi performs the simulation,

**helping you using it more effectively**

by making informed decisions when adjusting parameters.

Obi models all physical simulations as a set of **particles** and **constraints**. Particles are freely-moving lumps of matter, and constraints are rules that control their behavior.

Each constraint takes a set of particles and (optionally) some information about the "outside" world as input: colliders, rigidbodies, wind, athmospheric pressure, etc. Then it modifies the particles' positions so that they satisfy a certain condition.

For instance, some constraints might try to keep two particles within a certain distance from each other (**distance constraints**). Other constraints will try to ensure that a particle cannot go inside a collider (**collision constraints**), or place the particle in a position consistent with the air flow around it (**aerodynamic constraints**)

Obi uses a simulation paradigm known as position-based dynamics, or **PBD** for short. In PBD, forces and velocities have a somewhat secondary role in simulation, and positions are used instead.

## Position-based dynamics

At the beginng of every simulation step, Obi moves each particle from its current position to a **new, tentative position** according to its **velocity** and the **timestep size**. This tentative position probably violates many of the constraints: it could be inside a collider, or far away from other particles linked to it trough distance constraints.

![](https://obi.virtualmethodstudio.com/manual/images/v5/simulation/step1.png) _A particle is advanced from its starting position (green) to its tentative position (red), calculated using only the particle velocity. Sadly, this tentative position intersects a collider, so we cannot advance the particle there immediately._

So, this position needs to be **adjusted** so that it meets all conditions imposed by the **constraints** affecting that particle. By adjusting the tentative position, we are also indirectly adjusting the particle's velocity.

![](https://obi.virtualmethodstudio.com/manual/images/v5/simulation/step2.png)

_The tentative position (red) is corrected so that it satisfies the collision constraint: no particle can be inside a collider._

If we repeat this process every frame -predict tentative position, correct tentative position, advance to corrected position-, we get something like this:

![](https://obi.virtualmethodstudio.com/manual/images/v5/simulation/collision.gif)

_Only the green position is ever rendered to the screen, so we see a smooth animation of a particle following the laws of physics._

Sometimes, enforcing a constraint can violate another, and this makes it difficult to find a new position that satisfies all constraints. Obi will try to find a global solution to all constraints in an **iterative** fashion. With each iteration, we will get a **better solution**, closer to satisfying **all constraints simultaneously.**

There's two ways Obi can iterate over all constraints: in a **sequential** or **parallel** fashion. In **sequential** mode, each constraint is evaluated and the resulting adjustments to particle positions *immediately* applied, before advancing to the next constraint. Because of this, the order in which constraints are iterated has a slight impact on the final result. In **parallel** mode, all constraints are evaluated in a first pass. Then in a second pass, adjustments for each particle are averaged and applied. Because of this, parallel mode is **order-independent**, however it approaches the ground-truth solution more slowly.

In the following animations, three particles (**A**, **B** and **C**) generate two collision constraints which are then solved. This all happens during a single simulation step:

![](https://obi.virtualmethodstudio.com/manual/images/convergence/GaussSeidel.gif)

_Two collision constraints solved in sequential mode._

![](https://obi.virtualmethodstudio.com/manual/images/convergence/Jacobi.gif)

_Two collision constraints solved in parallel mode. Note it takes 6 parallel iterations to reach the same result we get with only 3 sequential iterations._

Each additional iteration will get your simulation closer to the ground-truth, but will also slightly erode performance. So the amount of iterations acts as a slider between **performance -few iterations-** and **quality -many iterations-.**

In most cases, **larger simulations** (those that have more constraints, like long/high-resolution ropes) need a higher amount of iterations.

An insufficiently high iteration count will almost always manifest as some sort of unwanted softness/stretchiness, depending on which constraints could not be fully satisfied:

- Stretchy cloth/ropes if **distance constraints** could not be met.
- Bouncy, compressible fluid if **density constraints** could not be met.
- Weak, soft collisions if **collision constraints** could not be met, and so on.

Sometimes you can take advantage of under-solved constraints if you need elastic/stretchy behavior. Instead of increasing constraint compliance (that is, elasticity),

**simply spend less iterations on them**

. You could use a lot of iterations to ensure the simulation is high-quality... but the naked eye cannot tell apart a cheap, low-quality simulation from an expensive, high-quality simulation of a very elastic object.

Once all iterations for this step have been carried out and the particle position has been adjusted, a **new velocity** is calculated using position differentiation, and a new simulation step can start. Here's an animation showing the complete process over multiple steps:

![](https://obi.virtualmethodstudio.com/manual/images/v5/simulation/iterative_projection.gif)

_Only the green positions are rendered at the end of each step. The red positions are tentative positions, initially calculated using only the particle velocity at the beginning of the step, then refined over multiple iterations every step. Only after we are done iterating can particles move to the tentative -now adjusted, and final- position._

A *very* effective way to reduce the amount of iterations we need to ensure constraints are satisfied is to reduce the simulation **timestep size**. This can be accomplished either by increasing the amount of **substeps** in our [fixed updater](https://obi.virtualmethodstudio.com/manual/6.1/updaters.html), or decreasing Unity's *fixed timestep* (found in ProjectSettings->Time). Intuitively speaking, taking smaller steps when advancing the simulation causes the tentative position calculated at the beginning of each step to be closer to the valid position we start from. This way, we need less iterations to arrive at a new valid position.

Note that reducing the timestep/increasing the amount of substeps also has an associated cost. But for the same cost in performance, the quality improvement you get by reducing the timestep size is greater than you'd get by keeping the same timestep size and using more iterations.

![](https://obi.virtualmethodstudio.com/manual/images/v5/simulation/01_1_its.gif)

_With a timestep of 0.1 ms, 1 iteration per step, the rope is very stretchy._

![](https://obi.virtualmethodstudio.com/manual/images/v5/simulation/01_10_its.gif)

_Increasing iterations to 10 keeps it taut, but dampens dynamics and reduces performance._

![](https://obi.virtualmethodstudio.com/manual/images/v5/simulation/001_1_its.gif)

_With a timestep of 0.01 ms, only one iteration is enough to eliminate stretching and achieve more lively dynamics._

Unlike other engines, Obi allows you to set the amount of iterations spent in each type of constraint **individually**. Each one will affect the simulation in a different way, depending on what the specific type of constraint does, so you can really fine tune your simulation:

## Constraint types

### Collision constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiCollisionMaterialIcon.png)

Collision constraints try to **keep particles outside of colliders**. High iteration counts will yield more robust collision detection when there are multiple colllisions per particle.

### Particle collision constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiCollisionMaterialIcon.png)

Identical to collision constraints, but for when collisions happen between particles.

### Distance constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiDistanceConstraintsIcon.png)

Each distance constraint tries to keep two particles at a fixed distance form each other. These are responsible for the **elasticity of cloth and ropes**. High iteration counts will allow them to reach higher stiffnesses, so your ropes/cloth will be less stretchy.

### Pin constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiPinConstraintsIcon.png)

A pin constraint will apply forces to **a particle** and a **rigidbody** so that they maintain their relative position. They are created and used by [dynamic attachments](https://obi.virtualmethodstudio.com/manual/6.1/attachments.html). High iteration counts will reduce the amount of drift at the pin location, making the attachment more robust.

### Volume constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiVolumeConstraintsIcon.png)

Each volume constraint takes a group of particles positioned at the vertices of a mesh, and tries to maintain the mesh volume. Used to **inflate cloth and create balloons**. High iteration counts will allow the ballons to reach higher pressures, and keep their shape more easily.

### Aerodynamic constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiAerodynamicConstraintsIcon.png)

This is the only type of constraint that doesn't have an iteration count. They are always applied only once, that is enough. Used to simulate **wind**.

### Bend constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiBendConstraintsIcon.png)

Each bend constraint will work on three particles, trying to get them in a straight line. These are used to make cloth and ropes **resistant to bending**. As with distance constraints, high iteration counts will allow them to reach higher stiffness.

### Tether constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiTetherConstraintsIcon.png)

These constraints are used to **reduce stretching of cloth**, when increasing the amount of distance constraint iterations would be too expensive. Generally 1-4 iterations are enough for tether constraints.

### Skin constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiSkinConstraintsIcon.png)

Skin constraints are used to keep **skeletally animated cloth close to its skinned shape**. They are mostly used for character clothing. Generally 1-2 iterations are enough for skin constraints.

### Density constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiEmitterMaterialFluidIcon.png)

Each density constraint tries to keep the amount of mass in the neighborhood around a particle constant. This will push out particles getting too close (as that would increase the mass) and pull in particles going away (which results in surface tension effects). Used to simulate **fluids**. High iteration counts will make the fluid more incompressible, so it will behave less like jelly.

### Shape matching constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiShapeMatchingConstraintsIcon.png)

Each shape matching constraint records a rest shape for a group of particles, then adjusts their positions so that they maintain this shape as closely as possible. These are used by **softbodies**.

### Stretch/shear constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiStretchShearConstraintsIcon.png)

Stretch/shear constraints adjust the position of a pair of particles along the axis of a reference frame, determined by a rotation quaternion. These are used by **rods**.

### Bend/Twist constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiBendTwistConstraints Icon.png)

Bend/twist constraints adjust the orientation of a pair of particles to prevent both bending and twisting. These are used by **rods**.

### Chain constraints ![](https://obi.virtualmethodstudio.com/manual/images/icons/48/ObiChainConstraints Icon.png)

Chain constraints take a list of particles and try to maintain their total length using a direct, non-iterative solver. These are used by **rods**.

Takeaway message from this section: If your rope/cloth/softbody/fluid is too stretchy or bouncy, you should try:

- Increasing the amount of **substeps** in the updater.
- Increasing the amount of **constraint iterations.**
- Decreasing Unity's **fixed timestep** .

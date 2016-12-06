#!/usr/bin/env python
#-*- coding:utf-8 -*-
import time

import math
from Cython.Includes.cpython.exc import PyErr_CheckSignals

from trajectory_msgs.msg import JointTrajectory
from std_msgs.msg import String
from sensor_msgs.msg import JointState, Temperature, Imu
from humanoid_league_msgs.msg import AdditionalServoData
from bitbots_speaker.msg import Speak
from bitbots_cm730.srv import SwitchMotorPower


import rospy

from .pose.pose import Joint, Pose
from .lowlevel.controller.controller import CM730, ID_CM730, MX28, BulkReadPacket, MultiMotorError, SyncWritePacket


class cm730(object):
    """
    Takes core of the communication with the CM730 (and therefore with the servos). Constantly updates servo data
    and sets goal values to the servos.
    """

    def __init__(self):
        rospy.init_node('bitbots_cm730', anonymous=False)
        rospy.Subscriber("/MotorGoals", JointTrajectory, self.update_motor_goals)
        self.joint_publisher = rospy.Publisher('/joint_states', JointState, queue_size=10)
        self.speak_publisher = rospy.Publisher('/speak', String, queue_size=10)
        self.temp_publisher = rospy.Publisher('/temperatur', Temperature, queue_size=10)
        self.imu_publisher = rospy.Publisher('/imu', Imu, queue_size=10)
        self.motor_power_service = rospy.Service("switch_motor_power", SwitchMotorPower, self.switch_motor_power_service_call)

        self.raw_accel = IntDataVector(0, 0, 0)
        self.raw_gyro = IntDataVector(0, 0, 0)
        self.button1 = 0
        self.button2 = 0
        self.last_io_success = 0

        joints = rospy.get_param("/joints")
        robot_type_name = rospy.get_param("/RobotTypeName")
        self.motors = rospy.get_param(robot_type_name + "/motors")

        self.read_packet_stub = list()
        self.read_packet2 = BulkReadPacket()
        self.read_packet3_stub = list()
        self.init_read_packet()

        #problem is, that the number of motors is not known at build time, so write them into params now
        for motor in joints:
            min_value = -180
            max_value = 180
            if 'max' in motor['limits']:
                max_value = motor['limits']['max']
            if 'min' in motor['limits']:
                min_value = motor['limits']['min']
            rospy.set_param(str(motor['name']), {'min': min_value, 'max': max_value})
        #start the endless loop
        self.update_forever()


    cdef update_motor_goals(self, msg):
        """ Callback for subscription on motorgoals topic.
        We can only handle the first point of a JointTrajectory :( """
        joints = msg.joint_names
        #we can handle only one position, no real trajectory
        positions = msg.points[0].position
        for joint in joints:
            if positions[joint] > joint.max:
                self.motor_goals[joint] = joint.max
                rospy.logwarn("Joint command over max. Joint: %s Position: %f", (joint, positions[joint]))
            elif positions[joint] < joint.min:
                self.motor_goals[joint] = joint.max
                rospy.logwarn("Joint command under min. Joint: %s Position: %f", (joint, positions[joint]))
            else:
                self.motor_goals[joint] = positions[joint]

    cdef set_motor_ram(self):
        """
        This method sets the values in the RAM of the motors, dependent on the values in the config.
        """
        if rospy.get_param('/cm730/setMXRam', False):
            rospy.loginfo("setting MX RAM")
            if self.cm_370:
                self.ctrl.write_register(ID_CM730, CM730.led_head, (255, 0, 0))
            for motor in self.motors:
                for conf in self.motor_ram_config:
                    self.ctrl.write_register(motor, MX28.get_register_by_name(conf),
                        self.motor_ram_config[conf])
            if self.cm_370:
                self.ctrl.write_register(ID_CM730, CM730.led_head, (0, 0, 0))
            rospy.loginfo("Setting RAM Finished")



    cpdef update_forever(self):
        """ Calls :func:`update_once` in an infite loop """
        cdef int iteration = 0, errors = 0
        cdef double duration_avg = 0, start = time.time()

        while True:
            self.update_once()

            # Signal check
            PyErr_CheckSignals()

            # Count to get the update frequency
            iteration += 1
            if iteration < 100:
                continue

            if duration_avg > 0:
                duration_avg = 0.5 * duration_avg + 0.5 * (time.time() - start)
            else:
                duration_avg = (time.time() - start)

            rospy.loginfo("Updates/Sec %f", iteration / duration_avg)
            iteration = 0
            start = time.time()

    cpdef update_once(self):
        """ Updates sensor data with :func:`update_sensor_data`, publishes the data and sends the motor commands.

            The sensordata from the last iteration will be provided as smoothed values in
            :attr:`smooth_accel` and :attr:`smooth_gyro`.
        """
        # get sensor data
        self.update_sensor_data()

        #todo irgendwas damit tun
        # Farbwerte für den Kopf holen
        self.led_eye = self.ipc.get_eye_color().xyz
        self.led_head = self.ipc.get_forehead_color().xyz

        # Send Messages to ROS
        self.publish_joints()
        self.publish_additional_servo_data()
        self.publish_IMU()
        self.publish_buttons()

        # send new position to servos
        self.update_motor_goals()

    cpdef update_sensor_data(self):
        result , cid_all_Values = self.sensor_data_read()
        if not result:
            return
        self.last_io_success = time.time()

        button, gyro, accel = self.parse_sensor_data(result, cid_all_Values)

        self.sensor_all_cid += 1

        self.update_gyro_data(gyro, accel)

        if button is not None:
            self.button1 = button & 1
            self.button2 = (button & 2) >> 1

    cdef sensor_data_read(self):
        """
        This Method is part of update_sensor_data,
                it communicates with the CM730-Board and extract its answer to a directly readable format
        """
        cdef dict result
        cdef int say_error
        # Das all_data Flag wird dazu benutzt das dann mehr daten
        # (tmperatur etc) abgefragt werden. Außerdem werden dann daten
        # an das Debug gesendet
        cdef int cid_all_Values = 0
        cdef BulkReadPacket read_packet
        if self.sensor_all_cid >= len(self.read_packet_stub):
            self.sensor_all_cid = 0
        try:
            if self.dxl_power:
                    read_packet = BulkReadPacket()
                    for i in range(self.sensor_all_cid - 1):
                        read_packet.add(self.read_packet3_stub[i][0],self.read_packet3_stub[i][1])
                    read_packet.add(self.read_packet_stub[self.sensor_all_cid][0],self.read_packet_stub[self.sensor_all_cid][1])
                    cid_all_Values = self.read_packet_stub[self.sensor_all_cid][0]
                    for i in range(self.sensor_all_cid +1, len(self.read_packet_stub)):
                        read_packet.add(self.read_packet3_stub[i][0],self.read_packet3_stub[i][1])
                    result = self.ctrl.process(read_packet)
            else:
                result = self.ctrl.process(self.read_packet2)
        except IOError, e:
            rospy.logdebug("Reading error: %s", str(e))
            if self.last_io_success > 0 and time.time() - self.last_io_success > 2:
                rospy.logwarn("Motion stuck!")
                msg = Speak()
                msg.text = "Motion stuck"
                self.speak_publisher.publish(msg)
                raise SystemExit("Motion stuck!")
            elif not  self.last_io_success > 0:
                self.last_io_success = time.time() + 5
                # This looks strange but is on purpose:
                # If it doesn't get any data, it should stop at _sometime_
            return (None, None)

        except MultiMotorError as errors:
            is_ok = True
            for e in errors:
                say_error = True
                err = e.get_error()
                if (err >> 0 & 1) == 1: # Imput Voltage Error
                    pass # mostly bullshit, ignore
                if (err >> 1 & 1) == 1: # Angel Limit Error
                    is_ok = False
                if (err >> 2 & 1) == 1: # Overheating Error
                    is_ok = False
                if (err >> 3 & 1) == 1: # Range Error
                    is_ok = False
                if (err >> 4 & 1) == 1: # Checksum Error
                    is_ok = False
                if (err >> 5 & 1) == 1: # Overload Error
                    say_error = False
                    if e.get_motor() in self.last_overload and \
                      time.time() - 2 < self.last_overload[e.get_motor()]:
                        self.overload_count[e.get_motor()] += 1
                        if self.overload_count[e.get_motor()] > 60:
                            rospy.logwarn("Raise long holding overload error")
                            is_ok = False # will be forwared
                    else:
                        # resetten, der letzte ist schon ne weile her
                        self.overload_count[e.get_motor()] = 0
                        rospy.logwarn("Motor %d has a Overloaderror, "
                            % e.get_motor() + " ignoring 60 updates")
                    self.last_overload[e.get_motor()] = time.time()
                if (err >> 6 & 1) == 1: # Instruction Error
                    is_ok = False
                if (err >> 7 & 1) == 1: # Unused
                    is_ok = False
                if say_error:
                    rospy.logerr(err, "A Motor has had an error:")
            if not is_ok:
                # If not everything was handled, we want to forward it
                # leads to shuting down the node
                raise
            # If an error was ignored, we have to test if a packed arrived
            # If not, we have to cancel, otherwise a uncomplete package will be handled
            result = errors.get_packets()
        return result, cid_all_Values


    cdef parse_sensor_data(self, object sensor_data, object cid_all_Values):
        """
        This Method is part of update_sensor_data,
                it takes the data which we just read from the CM370 Board and parse it into the right variables
        """
        cdef Pose pose = self.robo_pose

        cdef Joint joint
        cdef IntDataVector accel = None
        cdef IntDataVector gyro = None
        #cdef maxtmp = 0, maxcid = -1
        #cdef min_voltage = 1e10, max_voltage = 0
        cdef position = None, speed=None, load=None
        cdef voltage = None, temperature=None, button=None

        for cid, values in sensor_data.iteritems():
            if cid == ID_CM730:
                if not cid_all_Values == ID_CM730 and self.dxl_power:
                    gyro, accel = values
                else:
                    button, _, gyro, accel, voltage = values
                    rospy.loginfo("CM730.Voltage %d", voltage)
                    if voltage < 105:
                        rospy.logwarn("Low Voltage!!")
                    if voltage < 100:
                        self.low_voltage_counter += 1
                        if self.low_voltage_counter > 10:
                            # we delay the low voltag shutdown because sometimes the hardware is telling lies
                            self.speak_publisher.publish("Warning: Low Voltage! System Exit!")
                            rospy.logerr("SYSTEM EXIT: LOW VOLTAGE")
                            raise SystemExit("SYSTEM EXIT: LOW VOLTAGE (%d V)" % voltage/10)
                    else:
                        self.low_voltage_counter = 0
            else:
                joint = pose.get_joint_by_cid(cid)
                if not cid_all_Values == cid:
                    position = values[0]
                else:
                    position, speed, load, voltage, temperature = values
                    joint.set_load(load)

                position = position - self.joint_offsets[cid]
                joint.set_position(position)
                joint.set_load(load)
                joint.set_speed(speed)

                # Get aditional servo data, not everytime cause its not so important
                if cid_all_Values == cid:  # etwa alle halbe sekunde
                    #todo in publishing ändern
                    debug.log("MX28.%d.Temperatur" % cid, temperature)
                    debug.log("MX28.%d.Voltage" % cid, voltage)

                if temperature > 60:
                    fmt = "Motor cid=%d has a temperature of %1.1f°C: EMERGENCY SHUT DOWN!"
                    rospy.logwarn(fmt % (cid, temperature))
                    msg = Speak()
                    msg.text = fmt % temperature
                    self.speak_publisher.publish(msg)
                    raise SystemExit(fmt % (cid, temperature))

        return button, gyro, accel

    cdef update_gyro_data(self, object gyro, object accel):
        cdef double dt, t
        cdef CDataVector angles
        #cdef Vector3f accle
        if gyro is not None and accel is not None:
            t = time.time()
            dt = t - self.last_gyro_update_time
            self.last_gyro_update_time = t

            self.robo_accel = accel - IntDataVector(512, 512, 512)
            self.raw_gyro = gyro - IntDataVector(512, 512, 512)

            angles = calculate_robot_angles(deref(self.robo_accel.get_data_vector()))
            angles = self.gyro_kalman.get_angles_pvv(angles, gyro - IntDataVector(512, 512, 512), dt)
            self.robo_angle = wrap_data_vector(angles)
            self.robo_gyro = self.raw_gyro #self.gyro_kalman.get_rates_v()

            self.robot.update(self.robo_pose)
            new_angle = kinematic_robot_angle(self.robot, self.zmp_foot_phase)
            diff = (new_angle[0] - self.last_kinematic_robot_angle[0]) / dt, (new_angle[1] - self.last_kinematic_robot_angle[1]) / dt
            angles.set_x(new_angle[0])
            angles.set_y(new_angle[1])
            angles = self.kinematic_kalman.get_angles_vfv(angles, CDataVector(diff[0],diff[1], 0.0), dt)
            self.last_kinematic_robot_angle = new_angle
            self.kin_robo_angle = wrap_data_vector(angles)


            #print "robo accel %s, kinematic_angle %s, robAngle %s" % (self.robo_accel, self.kin_robo_angle, self.robo_angle)
            diff_angles = (self.robo_angle - self.kin_robo_angle)



    cpdef apply_goal_pose(self):
        cdef Pose pose = self.goal_pose
        cdef SyncWritePacket packet

        if pose is None:
            return

        # Hier werden die Augenfarben gesetzt.
        # Dabei kann in der Config angegeben werden ob die Augen bei Penalty
        # rot werden, und ob sie ansonsten überhaupt genutzt werden
        if self.cm_370:
            packet = SyncWritePacket((CM730.led_head, CM730.led_eye))
            #todo make this a service
            if self.state == STATE_PENALTY and rospy.get_param("/cm730/EyesPenalty", false):
                packet.add(ID_CM730, ((255, 0, 0), (0, 0, 0)))
            else:
                if rospy.get_param("/cm730/EyesOff", False):
                    packet.add(ID_CM730, ((0, 0, 0), (0, 0, 0)))
                else:
                    packet.add(ID_CM730, (self.led_head, self.led_eye))

            self.ctrl.process(packet)

        cdef Joint joint
        cdef Joint joint2
        cdef SyncWritePacket goal_packet = None
        cdef SyncWritePacket torque_packet = None
        cdef SyncWritePacket p_packet = None
        cdef SyncWritePacket i_packet = None
        cdef SyncWritePacket d_packet = None
        cdef int joint_value = 0

        #todo make this a service?
        if self.state != STATE_SOFT_OFF: #todo soft off existiert nicht mehr

            if not self.dxl_power:
                self.switch_motor_power(True)
                # Aktuallisieren der Pose, da die Motoren mit hoher
                # warscheinlichkeit anders liegen als beim ausstellen
                self.update_sensor_data()
                # hier abbrechen um Zuckungen zu vermeiden
                return

            goal_packet = SyncWritePacket((MX28.goal_position, MX28.moving_speed))
            for name, joint in pose.joints:
                if not joint.has_changed():
                    continue

                if joint.is_active():
                    joint_value = int(joint.get_goal()) + \
                        self.joint_offsets[joint.get_cid()]
                    goal_packet.add(joint.get_cid(),
                        (joint_value, joint.get_speed()))
                else:  # if joint.get_cid() != 30:
                    # Torque muss nur aus gemacht werden, beim setzen eines
                    # Goals geht es automatisch wieder auf 1
                    # Das Torque-Packet nur erstellen, wenn wir es benötigen
                    # 30 ist virtuell und braucht daher nicht gesetzt werden
                    if torque_packet is None:
                        torque_packet = SyncWritePacket((MX28.torque_enable,))

                    # Motor abschalten
                    torque_packet.add(joint.get_cid(), (0, ))

                if joint.get_p() != -1:
                    if p_packet is None:
                        p_packet = SyncWritePacket((MX28.p,))
                    p_packet.add(joint.get_cid(), (joint.get_p(), ))
                    #print "set p:", joint.get_p(), joint.get_cid()

                if joint.get_i() != -1:
                    if i_packet is None:
                        i_packet = SyncWritePacket((MX28.i,))
                    i_packet.add(joint.get_cid(), (joint.get_i(), ))
                    #print "set p:", joint.get_p(), joint.get_cid()

                if joint.get_d() != -1:
                    if d_packet is None:
                        d_packet = SyncWritePacket((MX28.d,))
                    d_packet.add(joint.get_cid(), (joint.get_d(), ))
                    #print "set p:", joint.get_p(), joint.get_cid()

                # changed-Property wieder auf false setzen.
                joint.reset()

            # Zielwerte setzen
            self.ctrl.process(goal_packet)
            if torque_packet is not None:
                # Motoren abschalten, wennn nötig.
                self.ctrl.process(torque_packet)
            if p_packet is not None:
                self.ctrl.process(p_packet)
            if i_packet is not None:
                self.ctrl.process(i_packet)
            if d_packet is not None:
                self.ctrl.process(d_packet)
        else:
            if self.dxl_power:
                self.switch_motor_power(False)


    cpdef switch_motor_power(self, state):
        # wir machen nur etwas be änderungen des aktuellen statusses
        if not self.cm_370:
            # without the cm370 we cant switch the motor power
            return
        if state and not self.dxl_power:
            # anschalten
            rospy.loginfo("Switch dxl_power back on")
            self.ctrl.write_register(ID_CM730, CM730.dxl_power, 1)
            # wir warten einen Augenblick bis die Motoeren auch wirklich wieder
            # wieder an und gebootet sind
            time.sleep(0.3)
            self.set_motor_ram()
            self.dxl_power = True
        elif (not state) and self.dxl_power:
            # ausschalten
            rospy.loginfo("Switch off dxl_power")
            # das sleep hier ist nötig da es sonst zu fehlern in der
            # firmware der Motoren kommt!
            # Vermutete ursache:
            # Schreiben der ROM area der Register mit sofortigen
            # abschalten des Stromes führt auf den motoren einen
            # vollst#ndigen Reset durch!
            time.sleep(0.3) # WICHTIGE CODEZEILE! (siehe oben)
            self.ctrl.write_register(ID_CM730, CM730.dxl_power, 0)
            self.dxl_power = False

    def switch_motor_power_service_call(self, req):
        return self.switch_motor_power(req.power)


    cdef void send_joints(self):
        """
        Sends the Joint States to ROS
        """
        cdef object ids = []
        cdef object positions = []
        cdef object speeds = []
        cdef object loads = []
        cdef msg = JointState()
        for name, joint in self.robo_pose.joints:
            ids.append(name)
            positions.append(math.radians(joint.position))
            speeds.append(joint.load)
            loads.append(joint.load)
        msg.header.stamp = rospy.Time.now()
        msg.name = ids
        msg.position = positions
        msg.velocity = speeds
        msg.effort = loads
        self.joint_publisher.publish(msg)

    def publish_additional_servo_data(self):
        msg = AdditionalServoData()
        cdef object temperatures = []
        for temp in self.temps:
            ros_temp = Temperature()
            ros_temp.header.stamp = rospy.Time.now()
            ros_temp.temperature = temp
            ros_temp.variance = 0
            temperatures.append(ros_temp)
        msg.temperature = temperatures
        msg.voltage = self.voltages
        self.temp_publisher(msg)

    def publish_IMU(self):
        msg = Imu()
        #todo check if this is realy linear and not angular acceleration
        msg.linear_acceleration = self.raw_accel
        # todo conversation to quaternion :(
        msg.orientation = self.raw_gyro
        self.imu_publisher(msg)

    def publish_buttons(self):
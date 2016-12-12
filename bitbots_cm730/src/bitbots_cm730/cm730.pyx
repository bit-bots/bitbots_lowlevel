#!/usr/bin/env python
#-*- coding:utf-8 -*-
import rospy
import time

from .lowlevel.controller.controller cimport BulkReadPacket, SyncWritePacket, Controller
from .lowlevel.controller.controller import MultiMotorError, MX28_REGISTER, ID_CM730, CM730_REGISTER

from bitbots_common.pose.pypose cimport PyJoint as Joint
from bitbots_common.util import Joints as JointManager


cdef class CM730(object):

    def __init__(self):
        self.using_cm_730 = True
        self.ctrl = Controller()
        self.read_packet_stub = list()
        self.read_packet2 = BulkReadPacket()
        self.read_packet3_stub = list()
        self.init_read_packet()

        self.low_voltage_counter = 0
        self.last_io_success = 0
        self.last_overload = {}
        self.overload_count = {}

        self.button1 = 0
        self.button2 = 0

        self.robo_pose = Pose()
        self.dxl_power = False
        self.sensor_all_cid = 0
        self.raw_gyro = IntDataVector(0, 0, 0)
        self.robo_accel = IntDataVector(0, 0, 0)

        robot_type_name = rospy.get_param("/RobotTypeName")
        self.motors = rospy.get_param(robot_type_name + "/motors")
        self.motor_ram_config = rospy.get_param("/mx28config/RAM")
        offsets = rospy.get_param("/offsets")

        self.joint_offsets =  {}
        joint_manager = JointManager()
        for i in range(1,31):
            self.joint_offsets[i] = offsets[joint_manager.get_motor_name(i)]


    cdef init_read_packet(self):
        """
        Initialise the :class:`BulkReadPacket` for communication with the motors

        Important: The motor in self.read_packet[i] has to be the same like in self.read_packet3[i], because
         while reading, single packages from 1 are inserted to 3.
        """
        for cid in self.motors:
            # if robot has this motor
            self.read_packet_stub.append((
                cid,
                (
                    MX28_REGISTER.present_position,
                    MX28_REGISTER.present_speed,
                    MX28_REGISTER.present_load,
                    MX28_REGISTER.present_voltage,
                    MX28_REGISTER.present_temperature
                )))
            self.read_packet3_stub.append((
                cid,
                (
                    MX28_REGISTER.present_position,
                )))
        if self.using_cm_730:
            self.read_packet_stub.append((
                ID_CM730,
                (
                    CM730_REGISTER.button,
                    CM730_REGISTER.padding31_37,
                    CM730_REGISTER.gyro,
                    CM730_REGISTER.accel,
                    CM730_REGISTER.voltage
                )))
            self.read_packet2.add(
                ID_CM730,
                (
                    CM730_REGISTER.button,
                    CM730_REGISTER.padding31_37,
                    CM730_REGISTER.gyro,
                    CM730_REGISTER.accel,
                    CM730_REGISTER.voltage
                ))
            self.read_packet3_stub.append((
                ID_CM730,
                (
                    CM730_REGISTER.gyro,
                    CM730_REGISTER.accel
                )))

        if len(self.read_packet_stub)!= len(self.read_packet3_stub):
            raise AssertionError("self.read_packet and self.read_packet3 have to be the same size")

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
        cdef int cid_all_values = 0
        cdef BulkReadPacket read_packet
        if self.sensor_all_cid >= len(self.read_packet_stub):
            self.sensor_all_cid = 0
        try:
            if self.dxl_power:
                    read_packet = BulkReadPacket()
                    for i in range(self.sensor_all_cid - 1):
                        read_packet.add(self.read_packet3_stub[i][0],self.read_packet3_stub[i][1])
                    read_packet.add(self.read_packet_stub[self.sensor_all_cid][0],self.read_packet_stub[self.sensor_all_cid][1])
                    cid_all_values = self.read_packet_stub[self.sensor_all_cid][0]
                    for i in range(self.sensor_all_cid +1, len(self.read_packet_stub)):
                        read_packet.add(self.read_packet3_stub[i][0],self.read_packet3_stub[i][1])
                    result = self.ctrl.process(read_packet)
            else:
                result = self.ctrl.process(self.read_packet2)
        except IOError, e:
            rospy.logdebug("Reading error: %s", str(e))
            if self.last_io_success > 0 and time.time() - self.last_io_success > 2:
                #we tell that we are stuck
                return -1, -1
            elif not  self.last_io_success > 0:
                self.last_io_success = time.time() + 5
                # This looks strange but is on purpose:
                # If it doesn't get any data, it should stop at _sometime_
            return None, None

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
                        # reset, the last was a while ago
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
                # leads to shutting down the node
                raise
            # If an error was ignored, we have to test if a packed arrived
            # If not, we have to cancel, otherwise a uncomplete package will be handled
            result = errors.get_packets()

        self.last_io_success = time.time()
        return result, cid_all_values


    cdef parse_sensor_data(self, object sensor_data, int cid_all_values):
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
                #this is a reponse package from cm730
                if not cid_all_values == ID_CM730 and self.dxl_power:
                    #only IMU values
                    gyro, accel = values
                else:
                    #get all values
                    button, _, gyro, accel, voltage = values
                    rospy.loginfo("CM730.Voltage %d", voltage)
                    if voltage < 105:
                        rospy.logwarn("Low Voltage!!")
                    if voltage < 100:
                        self.low_voltage_counter += 1
                        if self.low_voltage_counter > 10:
                            # we delay the low voltag shutdown because sometimes the hardware is telling lies
                            return -1, voltage, -1
                    else:
                        self.low_voltage_counter = 0
            else:
                joint = pose.get_joint_by_cid(cid)
                if not cid_all_values == cid:
                    position = values[0]
                else:
                    position, speed, load, voltage, temperature = values
                    joint.set_load(load)

                position = position - self.joint_offsets[cid]
                joint.set_position(position)
                joint.set_load(load)
                joint.set_speed(speed)

                # Get aditional servo data, not everytime cause its not so important
                if cid_all_values == cid:  # etwa alle halbe sekunde
                    joint.set_temperature(temperature)
                    joint.set_voltage(voltage)

                if temperature > 60:
                    fmt = "Motor cid=%d has a temperature of %1.1f°C: EMERGENCY SHUT DOWN!"
                    rospy.logwarn(fmt % (cid, temperature))
                    raise SystemExit(fmt % (cid, temperature))
        self.sensor_all_cid += 1
        return button, gyro, accel


    cdef set_motor_ram(self):
        """
        This method sets the values in the RAM of the motors, dependent on the values in the config.
        """
        if rospy.get_param('/cm730/setMXRam', False):
            rospy.loginfo("setting MX RAM")
            if self.using_cm_730:
                self.ctrl.write_register(ID_CM730, CM730_REGISTER.led_head, (255, 0, 0))
            for motor in self.motors:
                for conf in self.motor_ram_config:
                    self.ctrl.write_register(motor, MX28_REGISTER.get_register_by_name(conf),
                        self.motor_ram_config[conf])
            if self.using_cm_730:
                self.ctrl.write_register(ID_CM730, CM730_REGISTER.led_head, (0, 0, 0))
            rospy.loginfo("Setting RAM Finished")

    cdef apply_goal_pose(self, object goal_pose):
        cdef Pose pose = goal_pose
        cdef SyncWritePacket packet

        if pose is None:
            return

        # Hier werden die Augenfarben gesetzt.
        # Dabei kann in der Config angegeben werden ob die Augen bei Penalty
        # rot werden, und ob sie ansonsten überhaupt genutzt werden
        if self.using_cm_730:
            packet = SyncWritePacket((CM730_REGISTER.led_head, CM730_REGISTER.led_eye))
            #todo make this a service
            #if self.state == STATE_PENALTY and rospy.get_param("/cm730/EyesPenalty", false):
            #    packet.add(ID_CM730, ((255, 0, 0), (0, 0, 0)))
            #else:
            if rospy.get_param("/cm730/EyesOff", False):
                packet.add(ID_CM730, ((0, 0, 0), (0, 0, 0)))
            else:
                #todo this looks like it even didnt work before
                #packet.add(ID_CM730, (self.led_head, self.led_eye))
                pass

            self.ctrl.process(packet)

        cdef Joint joint
        cdef Joint joint2
        cdef SyncWritePacket goal_packet = None
        cdef SyncWritePacket torque_packet = None
        cdef SyncWritePacket p_packet = None
        cdef SyncWritePacket i_packet = None
        cdef SyncWritePacket d_packet = None
        cdef int joint_value = 0


        if not self.dxl_power:
            self.switch_motor_power(True)
            # We do nothing, so the pose gets updated before acting
            return

        goal_packet = SyncWritePacket((MX28_REGISTER.goal_position, MX28_REGISTER.moving_speed))
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
                    torque_packet = SyncWritePacket((MX28_REGISTER.torque_enable,))

                # Motor abschalten
                torque_packet.add(joint.get_cid(), (0, ))

            if joint.get_p() != -1:
                if p_packet is None:
                    p_packet = SyncWritePacket((MX28_REGISTER.p,))
                p_packet.add(joint.get_cid(), (joint.get_p(), ))
                #print "set p:", joint.get_p(), joint.get_cid()

            if joint.get_i() != -1:
                if i_packet is None:
                    i_packet = SyncWritePacket((MX28_REGISTER.i,))
                i_packet.add(joint.get_cid(), (joint.get_i(), ))
                #print "set p:", joint.get_p(), joint.get_cid()

            if joint.get_d() != -1:
                if d_packet is None:
                    d_packet = SyncWritePacket((MX28_REGISTER.d,))
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

    cdef switch_motor_power(self, bool state):
        # wir machen nur etwas be änderungen des aktuellen statusses
        if not self.using_cm_730:
            # without the cm370 we cant switch the motor power
            return
        if state and not self.dxl_power:
            # anschalten
            rospy.loginfo("Switch dxl_power back on")
            self.ctrl.write_register(ID_CM730, CM730_REGISTER.dxl_power, 1)
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
            self.ctrl.write_register(ID_CM730, CM730_REGISTER.dxl_power, 0)
            self.dxl_power = False